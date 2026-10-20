import Foundation

/// Carries out the model's tool calls for the pipeline: finds the provider, checks the call, asks for the
/// user's "oui" when the action is sensitive, and remembers the last action so that "annule" can take it back.
/// The model decides nothing here: the risk of a tool, the yes/no and the undo are the app's.
public actor ToolRunner {
    /// What the app says, and what goes into the history for the model.
    public struct Reply: Sendable {
        public var spoken: String
        public var forModel: JSONValue
        /// The call was refused because of its arguments: the model gets one chance to correct it.
        public var retryable: Bool
        /// The model says the answer itself, from `forModel` (see `ToolOutcome.modelSpeaks`); `spoken` if it gives nothing.
        public var modelSpeaks = false
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
    private var pending: (call: ToolCall, provider: any ToolProvider, at: Date)?
    /// Drops the pending action once its time is up, so that its provider knows (a task read back and shown on
    /// screen disappears).
    private var expiry: Task<Void, Never>?
    private var last: (outcome: ToolOutcome, provider: any ToolProvider, at: Date)?

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
        if let pending, now.timeIntervalSince(pending.at) < Self.actionLifetime {
            switch ReplyMatcher.confirmation(text) {
            case .yes: return .confirm
            case .no: return .decline
            default: return nil  // something else: the action keeps waiting, the model answers
            }
        }
        if ReplyMatcher.isCancel(text), let last, now.timeIntervalSince(last.at) < Self.actionLifetime {
            return .undo
        }
        return nil
    }

    /// Handles an interception; nil when it no longer applies (the action expired meanwhile).
    public func resolve(_ interception: Interception, context: ToolContext) async -> Reply? {
        guard stillApplies(interception, now: context.now) else { return nil }
        switch interception {
        case .confirm:
            guard let pending else { return nil }
            self.pending = nil
            expiry?.cancel()
            return await perform(pending.call, with: pending.provider, risk: .sensitive, context: context)
        case .decline:
            await dropPending()
            return Reply(spoken: ActionPhrases.declined(context.language),
                         forModel: ["statut": "abandonné à la demande de l'utilisateur"], retryable: false)
        case .undo:
            guard let last else { return nil }
            self.last = nil
            guard let token = last.outcome.undo else {
                return Reply(spoken: last.outcome.cannotUndo ?? ActionPhrases.cannotUndo(context.language),
                             forModel: ["statut": "impossible à défaire"], retryable: false)
            }
            do {
                let spoken = try await last.provider.undo(token, context: context)
                return Reply(spoken: spoken, forModel: ["statut": "annulé"], retryable: false)
            } catch let refusal as ToolRefusal {
                return Reply(spoken: refusal.spoken, forModel: ["erreur": .string(refusal.forModel)], retryable: false)
            } catch {
                return Reply(spoken: ActionPhrases.saveFailed(context.language),
                             forModel: ["erreur": .string("\(error)")], retryable: false)
            }
        }
    }

    private func stillApplies(_ interception: Interception, now: Date) -> Bool {
        switch interception {
        case .confirm, .decline: pending.map { now.timeIntervalSince($0.at) < Self.actionLifetime } ?? false
        case .undo: last.map { now.timeIntervalSince($0.at) < Self.actionLifetime } ?? false
        }
    }

    /// Checks a call and carries it out, or asks for confirmation first. A misspelled tool name is read as the
    /// tool's; a name that stands for none is refused with the real ones, for the model's second try.
    public func handle(_ call: ToolCall, context: ToolContext) async -> Reply {
        await dropPending()  // a new request replaces an action still waiting for its "oui"
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
            pending = (call, provider, context.now)
            expiry?.cancel()
            let at = context.now
            expiry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.actionLifetime))
                guard !Task.isCancelled else { return }
                await self?.expire(at)
            }
            return Reply(spoken: spoken, forModel: ["statut": "en attente du oui de l'utilisateur"], retryable: false)
        }
        return await perform(call, with: provider, risk: risk, context: context)
    }

    private func perform(_ call: ToolCall, with provider: any ToolProvider, risk: ToolRisk,
                         context: ToolContext) async -> Reply
    {
        do {
            let outcome = try await provider.perform(call, context: context)
            if risk != .read { last = (outcome, provider, context.now) }
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
        guard pending?.at == at else { return }
        await dropPending()
    }

    private func dropPending() async {
        expiry?.cancel()
        expiry = nil
        guard let pending else { return }
        self.pending = nil
        await pending.provider.dropped(pending.call)
    }

    /// A new conversation: nothing waits for a "oui" any more, and "annule" has nothing to take back.
    public func resetConversation() async {
        await dropPending()
        last = nil
        for provider in providers { await provider.resetConversation() }
    }
}

extension ToolRunner.Reply {
    /// A refused call: the refusal's question for the user, and its result for the model (`ToolRefusal.result`).
    init(_ refusal: ToolRefusal, of call: ToolCall) {
        self.init(spoken: refusal.spoken, forModel: refusal.result(for: call), retryable: refusal.retryable)
    }
}
