import Foundation

/// Carries out the model's tool calls for the pipeline: finds the provider, checks the call, asks for the
/// user's "oui" when the action is sensitive, and remembers the last request's actions so that "annule" can take them
/// back. The model decides nothing here: the risk of a tool, the yes/no and the undo are the app's.
///
/// A request may hold several calls (the user asked for several things at once): they are handled one after the other,
/// in the order the model wrote them. The request begins once (`beginRequest`, or `handle` without `sameRequest`): what
/// waited for a "oui" is dropped then, not at each call. Its sensitive calls wait together, for one "oui" that carries
/// them all out, in order; "annule" takes back all its actions, in reverse order.
public actor ToolRunner {
    /// What the app says, and what goes into the history for the model.
    public struct Reply: Sendable {
        public var spoken: String
        public var forModel: JSONValue
        /// The call was refused because of its arguments: the model gets one chance to correct it.
        public var retryable: Bool
        /// The model says the answer itself, from `forModel` (see `ToolOutcome.modelSpeaks`); `spoken` if it gives nothing.
        public var modelSpeaks = false
        /// The call was refused (`spoken` is then the app's question about it), whether the model may correct it or not.
        public var refusal: ToolRefusal?
        /// A sensitive call, which waits for the user's "oui": `spoken` is its question (`ToolProvider.summary`). With
        /// other sensitive calls in the same request, the app asks one question for them all (`pendingQuestion`).
        public var waitsForYes = false
    }

    /// A short answer the app handles itself.
    public enum Interception: Sendable, Equatable {
        /// "oui" to an action waiting for confirmation.
        case confirm
        /// "non" to it.
        case decline
        /// "annule" right after an action.
        case undo
    }

    /// How long an action waits for its "oui", and how long "annule" can take back the last one.
    public static let actionLifetime: TimeInterval = 120

    private let providers: [any ToolProvider]
    /// The built-in actions are among the providers (reminders and calendar, timers, shortcuts): the system prompt gets
    /// their part, and the smallest model their example exchanges. False for the tools offered without them (Claude
    /// Code, the web search, the built-in sources).
    public nonisolated let offersActions: Bool
    private var byName: [String: any ToolProvider] = [:]
    /// The tools' names, in the providers' order.
    private var names: [String] = []
    /// The tools whose provider says something of its own while the model writes a call to them.
    private var ownPhrases: Set<String> = []
    /// The sensitive calls of the last request that wait for the user's "oui", in order, with their questions; since
    /// `pendingSince`.
    private var pending: [(call: ToolCall, provider: any ToolProvider, summary: String)] = []
    private var pendingSince: Date?
    /// Drops the pending actions once their time is up, so that their providers know (a task read back and shown on
    /// screen disappears).
    private var expiry: Task<Void, Never>?
    /// The actions of the last request that did any, in the order they were carried out (those carried out after its
    /// "oui" too), for "annule"; since the last one, `lastAt`.
    private var last: [(outcome: ToolOutcome, provider: any ToolProvider)] = []
    private var lastAt: Date?
    /// `last` holds the request under way's own actions (otherwise its first one replaces them).
    private var lastIsThisRequest = false

    public init(providers: [any ToolProvider], actions: Bool = true) {
        self.providers = providers
        offersActions = actions
    }

    /// Every tool, in the providers' order (asks each provider again: call it when the list may have changed).
    public func tools() async -> [ToolSpec] {
        var specs: [ToolSpec] = []
        byName = [:]
        ownPhrases = []
        for provider in providers {
            for spec in await provider.tools() where byName[spec.name] == nil {
                byName[spec.name] = provider
                specs.append(spec)
                if await provider.waitingPhrase(for: spec.name, language: .french) != nil { ownPhrases.insert(spec.name) }
            }
        }
        names = specs.map(\.name)
        return specs
    }

    /// What the app says while the model writes a call: its tool's own phrase ("Je regarde ça sur internet, un
    /// instant."), or "Un instant, je m'en occupe tout de suite.". `tool` is nil when the call has just begun, its name
    /// not read yet: then nil when some tool has a phrase of its own (better wait for the name, a few tokens later).
    public func waitingPhrase(for tool: String?, language: SpeechLanguage) async -> String? {
        guard let tool else { return ownPhrases.isEmpty ? ActionPhrases.oneMoment(language) : nil }
        let name = ToolNames.match(tool, among: names) ?? tool
        if ownPhrases.contains(name), let provider = byName[name],
           let phrase = await provider.waitingPhrase(for: name, language: language)
        {
            return phrase
        }
        return ActionPhrases.oneMoment(language)
    }

    /// The call with the name of the tool it stands for, when the model misspelled it ("crer_rappel"); unchanged
    /// otherwise (`ToolNames`). It is what goes into the history, so the model does not see its slip again.
    public func named(_ call: ToolCall) -> ToolCall {
        guard let name = ToolNames.match(call.name, among: names), name != call.name else { return call }
        DebugLog.log("tool name \(call.name) read as \(name)")
        var named = call
        named.name = name
        return named
    }

    /// What the providers add to the system prompt, in their order.
    public func promptAddenda() async -> [String] {
        var addenda: [String] = []
        for provider in providers {
            if let addendum = await provider.promptAddendum() { addenda.append(addendum) }
        }
        return addenda
    }

    /// Whether the user's sentence is an answer the app handles itself. Changes nothing (the turn may still
    /// be dropped): `resolve` does the work once the turn is confirmed.
    public func interception(for text: String, now: Date) -> Interception? {
        if !pending.isEmpty, let since = pendingSince, now.timeIntervalSince(since) < Self.actionLifetime {
            switch ReplyMatcher.confirmation(text) {
            case .yes: return .confirm
            case .no: return .decline
            default: return nil  // something else: the actions keep waiting, the model answers
            }
        }
        if ReplyMatcher.isCancel(text), !last.isEmpty, let lastAt, now.timeIntervalSince(lastAt) < Self.actionLifetime {
            return .undo
        }
        return nil
    }

    /// Handles an interception; nil when it no longer applies (the action expired meanwhile).
    public func resolve(_ interception: Interception, context: ToolContext) async -> Reply? {
        guard stillApplies(interception, now: context.now) else { return nil }
        switch interception {
        case .confirm:
            // Each one in order, as if the user had asked for them one after the other.
            let confirmed = pending
            pending = []
            pendingSince = nil
            expiry?.cancel()
            var replies: [Reply] = []
            for action in confirmed {
                replies.append(await perform(action.call, with: action.provider, risk: .sensitive, context: context))
            }
            guard replies.count > 1 else { return replies.first }
            return Reply(spoken: replies.map(\.spoken).joined(separator: " "),
                         forModel: .array(replies.map(\.forModel)), retryable: false)
        case .decline:
            await dropPending()
            return Reply(spoken: ActionPhrases.declined(context.language),
                         forModel: ["statut": "abandonné à la demande de l'utilisateur"], retryable: false)
        case .undo:
            let actions = last
            last = []
            lastAt = nil
            return await undo(actions, context: context)
        }
    }

    /// Takes back the actions of a request, the last one first, and says what was taken back: a single one's own
    /// sentence; several in one sentence (`ActionPhrases.undone`), then what could not be taken back (a shortcut).
    private func undo(_ actions: [(outcome: ToolOutcome, provider: any ToolProvider)], context: ToolContext) async -> Reply {
        let language = context.language
        /// What was taken back, by action: its few words (nil: none) and its own sentence.
        var undone: [(name: String?, spoken: String)?] = Array(repeating: nil, count: actions.count)
        var others: [String] = []  // what could not be taken back, or went wrong
        for (index, action) in actions.enumerated().reversed() {
            guard let token = action.outcome.undo else {
                others.insert(action.outcome.cannotUndo ?? ActionPhrases.cannotUndo(language), at: 0)
                continue
            }
            let name = actions.count > 1 ? await action.provider.undoneName(token, language: language) : nil
            do {
                let spoken = try await action.provider.undo(token, context: context)
                if name == nil, actions.count > 1 {
                    others.insert(spoken, at: 0)
                } else {
                    undone[index] = (name, spoken)
                }
            } catch let refusal as ToolRefusal {
                others.insert(refusal.spoken, at: 0)
            } catch {
                DebugLog.log("undo of \(token.provider) failed: \(error)")
                others.insert(ActionPhrases.saveFailed(language), at: 0)
            }
        }
        let done = undone.compactMap { $0 }
        var sentences: [String] = []
        if done.count > 1 {
            sentences.append(ActionPhrases.undone(done.compactMap(\.name), language))
        } else if let one = done.first {
            sentences.append(one.spoken)
        }
        for sentence in others where !sentences.contains(sentence) { sentences.append(sentence) }
        let forModel: JSONValue = done.isEmpty ? ["statut": "impossible à défaire"] : ["statut": "annulé"]
        return Reply(spoken: sentences.joined(separator: " "), forModel: forModel, retryable: false)
    }

    private func stillApplies(_ interception: Interception, now: Date) -> Bool {
        switch interception {
        case .confirm, .decline:
            !pending.isEmpty && pendingSince.map { now.timeIntervalSince($0) < Self.actionLifetime } ?? false
        case .undo: !last.isEmpty && lastAt.map { now.timeIntervalSince($0) < Self.actionLifetime } ?? false
        }
    }

    /// A request begins: what waited for the user's "oui" is dropped (the new request replaces it), and its first action
    /// will replace those "annule" takes back. Once per request, before its first call (`handle` does it for a call
    /// handled on its own).
    public func beginRequest() async {
        await dropPending()
        lastIsThisRequest = false
    }

    /// The question for what waits for the user's "oui": a single call's own (`ToolProvider.summary`), or one for all
    /// the calls of the request (`ActionPhrases.pendingQuestion`). nil when nothing waits.
    public func pendingQuestion(_ language: SpeechLanguage) -> String? {
        pending.isEmpty ? nil : ActionPhrases.pendingQuestion(pending.map(\.summary), language)
    }

    /// Checks a call and carries it out, or asks for confirmation first. A misspelled tool name is read as the
    /// tool's; a name that stands for none is refused with the real ones, for the model's second try.
    /// `sameRequest`: the call is one more of the request begun before (`beginRequest`, or the call before); otherwise it
    /// begins one.
    public func handle(_ call: ToolCall, context: ToolContext, sameRequest: Bool = false) async -> Reply {
        if !sameRequest { await beginRequest() }  // a new request replaces what still waits for its "oui"
        let call = named(call)
        guard let provider = byName[call.name] else {
            return Reply(ToolRefusal(forModel: ToolNames.unknown(call.name, among: names),
                                     spoken: ActionPhrases.notUnderstood(context.language)), of: call)
        }
        do {
            try await provider.check(call, context: context)
        } catch let refusal as ToolRefusal {
            return Reply(refusal, of: call)
        } catch {
            return Reply(ToolRefusal(forModel: "\(error)", spoken: ActionPhrases.notUnderstood(context.language)), of: call)
        }
        let risk = await provider.risk(of: call)
        if risk == .sensitive {
            let spoken = await provider.summary(of: call, context: context)
            pending.append((call, provider, spoken))
            if pendingSince == nil {
                // One expiry for all the calls of the request, from the first one.
                pendingSince = context.now
                expiry?.cancel()
                let at = context.now
                expiry = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(Self.actionLifetime))
                    guard !Task.isCancelled else { return }
                    await self?.expire(at)
                }
            }
            return Reply(spoken: spoken, forModel: ["statut": "en attente du oui de l'utilisateur"], retryable: false,
                         waitsForYes: true)
        }
        return await perform(call, with: provider, risk: risk, context: context)
    }

    private func perform(_ call: ToolCall, with provider: any ToolProvider, risk: ToolRisk,
                         context: ToolContext) async -> Reply
    {
        do {
            let outcome = try await provider.perform(call, context: context)
            if risk != .read {
                if !lastIsThisRequest {
                    last = []
                    lastIsThisRequest = true
                }
                last.append((outcome, provider))
                lastAt = context.now
            }
            return Reply(spoken: outcome.spoken, forModel: outcome.forModel, retryable: false,
                         modelSpeaks: outcome.modelSpeaks)
        } catch let refusal as ToolRefusal {
            return Reply(refusal, of: call)
        } catch {
            DebugLog.log("tool \(call.name) failed: \(error)")
            return Reply(spoken: ActionPhrases.saveFailed(context.language),
                         forModel: ["erreur": .string("\(error)")], retryable: false)
        }
    }

    private func expire(_ at: Date) async {
        guard pendingSince == at else { return }
        await dropPending()
    }

    private func dropPending() async {
        expiry?.cancel()
        expiry = nil
        let dropped = pending
        pending = []
        pendingSince = nil
        for action in dropped { await action.provider.dropped(action.call) }
    }

    /// A new conversation: nothing waits for a "oui" any more, and "annule" has nothing to take back.
    public func resetConversation() async {
        await dropPending()
        last = []
        lastAt = nil
        lastIsThisRequest = false
        for provider in providers { await provider.resetConversation() }
    }
}

extension ToolRunner.Reply {
    /// A refused call: the refusal's question for the user, and its result for the model (`ToolRefusal.result`).
    init(_ refusal: ToolRefusal, of call: ToolCall) {
        self.init(spoken: refusal.spoken, forModel: refusal.result(for: call), retryable: refusal.retryable,
                  refusal: refusal)
    }
}
