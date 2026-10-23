@preconcurrency import EventKit
import Foundation
import VoiceCore

/// Reminders and calendar, through EventKit: every account macOS knows (iCloud, Google, Exchange, CalDAV).
/// OpenMaé never connects anywhere itself: macOS syncs the accounts.
///
/// Access is asked the first time the user requests something that needs it, not at launch; Maé says so just
/// before macOS shows its dialog. Every sentence said afterwards is built from the item read back from
/// EventKit, so the user hears what was really saved.
public actor CalendarTools: ToolProvider {
    public nonisolated let identifier = "calendar"
    private let store = EKEventStore()
    /// When set, every item Maé creates goes into a calendar and a reminder list of this name, created on first
    /// use: lets the feature be tried without changing the user's own calendars. Readings still cover them all.
    private let testCollection: String?

    private enum Item: Sendable, Equatable {
        case event(String)  // EventKit identifiers
        case reminder(String)
    }
    /// Saved values of an item, to put it back as it was ("annule" after a change).
    private struct Snapshot: Sendable {
        var calendar: String?  // identifier
        var title: String?
        var start: Date?
        var end: Date?
        var allDay = false
        var location: String?
        var due: DateComponents?
        var alarmDates: [Date] = []
    }
    private enum Undo: Sendable {
        case delete(Item)
        case restore(Item, Snapshot)
        /// Create again an item that was deleted, under its reference.
        case recreate(reference: String, Item, Snapshot)
    }

    /// Items created in this conversation, by the reference given to the model ("e1", "r2").
    private var created: [String: Item] = [:]
    private var lastCreated: String?
    private var eventCount = 0
    private var reminderCount = 0
    private var undos: [String: Undo] = [:]
    private var undoCount = 0
    /// The default calendar is named once per conversation, so the user knows where events go.
    private var calendarNamed = false
    /// A creation just refused for a detail the user gives again (its moment, its calendar or its list), which a change
    /// of the last item, or of an item never created, makes instead.
    private var refusedCreation = RefusedCreation()

    public init(testCollection: String? = nil) {
        self.testCollection = testCollection
    }

    /// Whether `modifier_element` offers a calendar and a list (`ActionCatalog.movesItems(on:)`): set for the tier's
    /// model before the tools are read.
    private var movesItems = false

    public func offerMoves(_ on: Bool) { movesItems = on }

    public func tools() -> [ToolSpec] { ActionCatalog.calendarTools(movingItems: movesItems) }

    /// A creation refused is kept with the calendar or the list the user's words name, when its call names none
    /// (`completed`): the answer then creates it there. Its moment is checked as it is carried out: on the day of the
    /// same creation refused just before, when the call gives an hour alone (`RefusedCreation.withRefusedDay`).
    public func check(_ call: ToolCall, context: ToolContext) throws {
        refusedCreation.checking(call)
        do {
            try ActionCatalog.check(refusedCreation.withRefusedDay(call, said: context.userSaid), context: context)
        } catch let refusal as ToolRefusal {
            refusedCreation.refused(completed(call, context), refusal, said: context.userSaid)
            throw refusal
        }
    }

    /// A creation with what the model left out of its call. No calendar (an event) or no list (a reminder): the one the
    /// user's words name among the writable ones, or the one of the same creation refused just before, or, when that
    /// one does not exist, the one the user's answer names (`ActionCatalog.withCollectionSaid`), found then as one the
    /// model names. An hour alone (« à 18 h ») after that refused creation's words gave the day and left the hour open
    /// (« jeudi après le travail »): that day (`RefusedCreation.withRefusedDay`).
    private func completed(_ call: ToolCall, _ context: ToolContext) -> ToolCall {
        ActionCatalog.withCollectionSaid(refusedCreation.withRefusedDay(call, said: context.userSaid), context: context,
                                         again: refusedCreation.collection(before: call),
                                         answer: refusedCreation.answer(before: call, said: context.userSaid)) {
            writable($0 ? .event : .reminder)
        }
    }

    public func resetConversation() {
        created = [:]
        lastCreated = nil
        undos = [:]
        calendarNamed = false
        refusedCreation.forget()
    }

    // MARK: - Access

    public enum Access: String, Sendable { case notAsked, granted, denied }

    /// Whether OpenMaé may read and write the calendar and the reminders (for the settings).
    public nonisolated static func access(to type: EKEntityType) -> Access {
        switch EKEventStore.authorizationStatus(for: type) {
        case .fullAccess: .granted
        case .notDetermined: .notAsked
        default: .denied
        }
    }

    private func ensureAccess(_ type: EKEntityType, context: ToolContext) async throws {
        let kind: ActionPhrases.Access = type == .event ? .calendar : .reminders
        switch EKEventStore.authorizationStatus(for: type) {
        case .fullAccess:
            return
        case .notDetermined:
            await context.say(ActionPhrases.askingAccess(kind, context.language))
            try? await Task.sleep(for: .seconds(1.5))  // let the user hear why before macOS asks
            let granted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let done: EKEventStoreRequestAccessCompletionHandler = { granted, _ in continuation.resume(returning: granted) }
                if type == .event { store.requestFullAccessToEvents(completion: done) }
                else { store.requestFullAccessToReminders(completion: done) }
            }
            DebugLog.log("calendar: access to \(type == .event ? "events" : "reminders") \(granted ? "granted" : "refused")")
            if granted {
                store.reset()
                return
            }
        default:
            break
        }
        throw ToolRefusal(forModel: "L'utilisateur n'a pas autorisé l'accès à \(type == .event ? "son calendrier" : "ses rappels").",
                          spoken: ActionPhrases.accessDenied(kind, context.language), retryable: false)
    }

    // MARK: - Carrying out a call

    /// A creation refused here (a calendar or a list that does not exist) is kept as one refused by `check` is.
    public func perform(_ call: ToolCall, context: ToolContext) async throws -> ToolOutcome {
        do {
            switch call.name {
            case ActionCatalog.createEvent.name: return try await createEvent(call, context)
            case ActionCatalog.createReminder.name: return try await createReminder(call, context)
            case ActionCatalog.readAgenda.name: return try await readAgenda(call, context)
            case ActionCatalog.listReminders.name: return try await listReminders(call, context)
            case ActionCatalog.changeItem.name: return try await change(call, context)
            case ActionCatalog.deleteItem.name: return try await delete(call, context)
            default:
                throw ToolRefusal(forModel: "Outil inconnu : \(call.name).",
                                  spoken: ActionPhrases.notUnderstood(context.language))
            }
        } catch let refusal as ToolRefusal {
            refusedCreation.refused(completed(call, context), refusal, said: context.userSaid)
            throw refusal
        }
    }

    private func createEvent(_ call: ToolCall, _ context: ToolContext) async throws -> ToolOutcome {
        try await ensureAccess(.event, context: context)
        let call = completed(call, context)
        let title = try ActionCatalog.title(call, context: context)
        let times = try ActionCatalog.eventTimes(call, context: context)
        let named = call.text("calendrier")
        let calendar = try eventCalendar(named: named, context: context)
        let asked = ActionCatalog.SavedItem(isEvent: true, title: title, date: times.start, end: times.end,
                                            hasTime: !times.allDay, place: call.text("lieu"),
                                            collection: calendar.calendarIdentifier)
        if let already = alreadyThere(asked, context) { return already }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = times.start
        event.endDate = times.end
        event.isAllDay = times.allDay
        event.location = call.text("lieu")
        event.calendar = calendar
        try store.save(event, span: .thisEvent, commit: true)
        let saved = event.eventIdentifier.flatMap { store.event(withIdentifier: $0) } ?? event
        DebugLog.log("calendar: event saved in “\(saved.calendar?.title ?? "?")”")

        eventCount += 1
        let reference = "e\(eventCount)"
        created[reference] = .event(saved.eventIdentifier)
        lastCreated = reference
        // Say which calendar once, or when the user named one.
        let sayCalendar = named != nil || !calendarNamed || testCollection != nil
        calendarNamed = true
        return ToolOutcome(
            spoken: ActionPhrases.eventCreated(
                title: saved.title ?? title, start: saved.startDate, end: saved.endDate, allDay: saved.isAllDay,
                calendarName: sayCalendar ? saved.calendar?.title : nil, context),
            forModel: describe(saved, reference: reference, context),
            undo: addUndo(.delete(.event(saved.eventIdentifier))))
    }

    private func createReminder(_ call: ToolCall, _ context: ToolContext) async throws -> ToolOutcome {
        try await ensureAccess(.reminder, context: context)
        let call = completed(call, context)
        let title = try ActionCatalog.title(call, context: context)
        let due = try ActionCatalog.reminderDue(call, context: context)
        let named = call.text("liste")
        let list = try reminderList(named: named, context: context)
        let asked = ActionCatalog.SavedItem(isEvent: false, title: title, date: due?.date, hasTime: due?.hasTime ?? false,
                                            collection: list.calendarIdentifier)
        if let already = alreadyThere(asked, context) { return already }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = list
        if let due {
            reminder.dueDateComponents = components(due.date, hasTime: due.hasTime, context)
            if due.hasTime { reminder.addAlarm(EKAlarm(absoluteDate: due.date)) }
        }
        try store.save(reminder, commit: true)
        let saved = store.calendarItem(withIdentifier: reminder.calendarItemIdentifier) as? EKReminder ?? reminder
        DebugLog.log("calendar: reminder saved in “\(saved.calendar?.title ?? "?")”")

        reminderCount += 1
        let reference = "r\(reminderCount)"
        created[reference] = .reminder(saved.calendarItemIdentifier)
        lastCreated = reference
        let when = dueDate(of: saved, context)
        return ToolOutcome(
            spoken: ActionPhrases.reminderCreated(
                title: saved.title ?? title, due: when?.date, hasTime: when?.hasTime ?? false,
                listName: named != nil || testCollection != nil ? saved.calendar?.title : nil, context),
            forModel: describe(saved, reference: reference, context),
            undo: addUndo(.delete(.reminder(saved.calendarItemIdentifier))))
    }

    /// The creation of an item created earlier in this conversation, in its own calendar or list, as EventKit has it now
    /// (`ActionCatalog.repeated`): not saved again. The user hears where the item is, and the model gets it, as the last
    /// item created (`ActionCatalog.alreadyThere`). Only items of the creation's kind are read (access to that kind was
    /// just checked), and only those still there: not deleted, nor done since for a reminder.
    private func alreadyThere(_ asked: ActionCatalog.SavedItem, _ context: ToolContext) -> ToolOutcome? {
        var states: [String: ActionCatalog.SavedItem] = [:]
        var found: [String: (described: JSONValue, collectionName: String)] = [:]
        for (reference, item) in created {
            switch item {
            case .event(let id) where asked.isEvent:
                guard let event = store.event(withIdentifier: id) else { continue }
                states[reference] = state(of: event)
                found[reference] = (describe(event, reference: reference, context), event.calendar?.title ?? "")
            case .reminder(let id) where !asked.isEvent:
                // Done since (ticked in the Reminders app): no longer there to do.
                guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder, !reminder.isCompleted
                else { continue }
                states[reference] = state(of: reminder, context)
                found[reference] = (describe(reminder, reference: reference, context), reminder.calendar?.title ?? "")
            default:
                continue
            }
        }
        guard let (reference, item) = ActionCatalog.repeated(asked, among: states, calendar: context.calendar),
              let existing = found[reference]
        else { return nil }
        DebugLog.log("calendar: \(asked.isEvent ? "event" : "reminder") already there, not saved again")
        lastCreated = reference
        return ActionCatalog.alreadyThere(item, described: existing.described, collectionName: existing.collectionName,
                                          context: context)
    }

    private func readAgenda(_ call: ToolCall, _ context: ToolContext) async throws -> ToolOutcome {
        try await ensureAccess(.event, context: context)
        guard let (start, end) = try ActionCatalog.period(call, context: context, required: true) else {
            throw DateCheck.refusal(.missing, key: "quand", raw: "", context: context)
        }
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .sorted { $0.startDate < $1.startDate }
        let items = events.map {
            ActionPhrases.Item(title: $0.title ?? "", date: max($0.startDate, start), hasTime: !$0.isAllDay)
        }
        return ToolOutcome(
            spoken: ActionPhrases.agenda(items, from: start, to: end, context),
            forModel: ["nombre": .int(events.count),
                       "evenements": .array(events.prefix(12).map { describe($0, reference: nil, context) })])
    }

    private func listReminders(_ call: ToolCall, _ context: ToolContext) async throws -> ToolOutcome {
        try await ensureAccess(.reminder, context: context)
        let period = try ActionCatalog.period(call, context: context, required: false)
        // Like the Today list of the Reminders app: a period that has already begun also takes what is still to do
        // from before it (earlier today, a reminder without a time, overdue ones).
        let from = period.flatMap { $0.0 > context.now ? $0.0 : nil }
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: from, ending: period?.1, calendars: nil)
        let timeZone = context.timeZone
        var found = await withCheckedContinuation { (continuation: CheckedContinuation<[Found], Never>) in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).map { Found($0, timeZone: timeZone) })
            }
        }
        if let end = period?.1 { found = found.filter { $0.due.map { $0 < end } ?? false } }
        let sorted = found.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
        let items = sorted.map { ActionPhrases.Item(title: $0.title, date: $0.due, hasTime: $0.hasTime) }
        return ToolOutcome(
            spoken: ActionPhrases.reminders(items, from: period?.0, to: period?.1, context),
            forModel: ["nombre": .int(sorted.count),
                       "rappels": .array(sorted.prefix(12).map { found in
                           ["titre": .string(found.title),
                            "echeance": found.due.map { .string(LocalDateTime.format($0, in: timeZone, withTime: found.hasTime)) }
                                ?? .null]
                       })])
    }

    /// A reminder as read from EventKit, in a form that can leave its callback.
    private struct Found: Sendable {
        var title: String
        var due: Date?
        var hasTime: Bool
        init(_ reminder: EKReminder, timeZone: TimeZone) {
            title = reminder.title ?? ""
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = reminder.dueDateComponents?.timeZone ?? timeZone
            due = reminder.dueDateComponents.flatMap { calendar.date(from: $0) }
            hasTime = reminder.dueDateComponents?.hour != nil
        }
    }

    // MARK: - Changing what was just created

    /// The item a call refers to: "dernier", or a reference given earlier ("e1"). Only what Maé created in
    /// this conversation can be changed or deleted.
    private func referenced(_ call: ToolCall, _ context: ToolContext) throws -> (key: String, item: Item) {
        let reference = call.text("reference") ?? "dernier"
        let key = ActionCatalog.meansLastItem(reference) ? lastCreated : reference
        guard let key, let item = created[key] else {
            throw ToolRefusal(forModel: "Aucun élément « \(reference) » créé dans cette conversation : seuls ceux-là "
                              + "peuvent être modifiés ou supprimés.",
                              spoken: ActionPhrases.nothingToChange(context.language))
        }
        return (key, item)
    }

    private func delete(_ call: ToolCall, _ context: ToolContext) async throws -> ToolOutcome {
        let (key, item) = try referenced(call, context)
        switch item {
        case .event(let id):
            try await ensureAccess(.event, context: context)
            guard let event = store.event(withIdentifier: id) else {
                throw ToolRefusal(forModel: "L'événement \(key) n'existe plus.",
                                  spoken: ActionPhrases.nothingToChange(context.language), retryable: false)
            }
            let before = snapshot(event)
            try store.remove(event, span: .thisEvent, commit: true)
            forget(id)
            return ToolOutcome(spoken: ActionPhrases.deleted(event: true, title: before.title ?? "", context.language),
                               forModel: ["id": .string(key), "statut": "supprimé"],
                               undo: addUndo(.recreate(reference: key, item, before)))
        case .reminder(let id):
            try await ensureAccess(.reminder, context: context)
            guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
                throw ToolRefusal(forModel: "Le rappel \(key) n'existe plus.",
                                  spoken: ActionPhrases.nothingToChange(context.language), retryable: false)
            }
            let before = snapshot(reminder)
            try store.remove(reminder, commit: true)
            forget(id)
            return ToolOutcome(spoken: ActionPhrases.deleted(event: false, title: before.title ?? "", context.language),
                               forModel: ["id": .string(key), "statut": "supprimé"],
                               undo: addUndo(.recreate(reference: key, item, before)))
        }
    }

    private func change(_ call: ToolCall, _ context: ToolContext) async throws -> ToolOutcome {
        // The item whose creation was just refused for a detail the user gave again, named as the last item (not one
        // created before it) or by an id that names none: created with what the change gives (another moment,
        // calendar or list; none, after a calendar or a list that does not exist: the one the user's answer names).
        if let creation = refusedCreation.creation(insteadOf: call, said: context.userSaid,
                                                   names: { writable($0 ? .event : .reminder) },
                                                   exists: { created[$0] != nil })
        {
            DebugLog.log("calendar: a change of an item never created, made as its creation")
            return try await perform(creation, context: context)
        }
        let (key, item) = try referenced(call, context)
        switch item {
        case .event(let id):
            try await ensureAccess(.event, context: context)
            guard let event = store.event(withIdentifier: id) else {
                throw ToolRefusal(forModel: "L'événement \(key) n'existe plus.",
                                  spoken: ActionPhrases.nothingToChange(context.language), retryable: false)
            }
            // Worked out before anything changes: a refused call (a calendar that does not exist, a change that changes
            // nothing, answered by the app at once: « C’est déjà dans ton calendrier « Travail »… ») leaves the event as
            // it was.
            let calendar = try ActionCatalog.collectionNamed(in: call, event: true).map {
                try eventCalendar(named: $0, current: event.calendar, context: context)
            }
            let current = state(of: event)
            let changed = try ActionCatalog.changed(current, by: call, collection: calendar?.calendarIdentifier,
                                                    collectionName: calendar?.title, reference: key, context: context)
            let before = snapshot(event)
            if changed.title != current.title { event.title = changed.title }
            if changed.place != current.place { event.location = changed.place }
            if let start = changed.date, let end = changed.end,
               start != current.date || end != current.end || changed.hasTime != current.hasTime
            {
                event.isAllDay = !changed.hasTime
                event.startDate = start
                event.endDate = end
            }
            let newCalendar = changed.collection != current.collection ? calendar : nil
            if let newCalendar { event.calendar = newCalendar }
            try save(event)
            let saved = reread(event, id: id)
            if newCalendar != nil { logMove(of: saved) }
            return ToolOutcome(
                spoken: ActionPhrases.eventChanged(title: saved.title ?? "", start: saved.startDate, end: saved.endDate,
                                                   allDay: saved.isAllDay, moved: changed.moved(from: current),
                                                   calendarName: newCalendar.map { saved.calendar?.title ?? $0.title },
                                                   context),
                forModel: describe(saved, reference: key, context),
                undo: addUndo(.restore(.event(saved.eventIdentifier ?? id), before)))
        case .reminder(let id):
            try await ensureAccess(.reminder, context: context)
            guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
                throw ToolRefusal(forModel: "Le rappel \(key) n'existe plus.",
                                  spoken: ActionPhrases.nothingToChange(context.language), retryable: false)
            }
            let list = try ActionCatalog.collectionNamed(in: call, event: false).map {
                try reminderList(named: $0, current: reminder.calendar, context: context)
            }
            let current = state(of: reminder, context)
            let changed = try ActionCatalog.changed(current, by: call, collection: list?.calendarIdentifier,
                                                    collectionName: list?.title, reference: key, context: context)
            let before = snapshot(reminder)
            if changed.title != current.title { reminder.title = changed.title }
            if changed.moved(from: current), let due = changed.date {
                reminder.dueDateComponents = components(due, hasTime: changed.hasTime, context)
                reminder.alarms?.forEach { reminder.removeAlarm($0) }
                if changed.hasTime { reminder.addAlarm(EKAlarm(absoluteDate: due)) }
            }
            let newList = changed.collection != current.collection ? list : nil
            if let newList { reminder.calendar = newList }
            try save(reminder)
            let saved = reread(reminder, id: id)
            if newList != nil { logMove(of: saved) }
            let when = dueDate(of: saved, context)
            return ToolOutcome(
                spoken: ActionPhrases.reminderChanged(title: saved.title ?? "", due: when?.date,
                                                      hasTime: when?.hasTime ?? false,
                                                      moved: changed.moved(from: current),
                                                      listName: newList.map { saved.calendar?.title ?? $0.title }, context),
                forModel: describe(saved, reference: key, context),
                undo: addUndo(.restore(.reminder(saved.calendarItemIdentifier), before)))
        }
    }

    /// An event just saved, read again from EventKit. In another calendar, EventKit may store it anew (in another
    /// account, it is a new event there): its identifier then changes ("if you change the calendar of an event, this ID
    /// will likely change", says EKEvent.h), and the reference given to the model follows it.
    private func reread(_ event: EKEvent, id: String) -> EKEvent {
        guard let now = event.eventIdentifier else { return event }
        if now != id { follow(.event(id), to: .event(now)) }
        return store.event(withIdentifier: now) ?? event
    }

    private func reread(_ reminder: EKReminder, id: String) -> EKReminder {
        let now = reminder.calendarItemIdentifier
        if now != id { follow(.reminder(id), to: .reminder(now)) }
        return store.calendarItem(withIdentifier: now) as? EKReminder ?? reminder
    }

    /// Where a change moved an item: the calendar or the list, and its account.
    private func logMove(of item: EKCalendarItem) {
        DebugLog.log("calendar: \(item is EKReminder ? "reminder" : "event") moved to “\(item.calendar?.title ?? "?")” "
                     + "(\(item.calendar?.source?.title ?? "?"))")
    }

    private func follow(_ old: Item, to new: Item) {
        for (reference, item) in created where item == old { created[reference] = new }
        DebugLog.log("calendar: saved under another identifier")
    }

    /// Saves a change; when EventKit refuses it (another account that does not take the item, say), the item keeps
    /// what was saved before, not the values set for the change.
    private func save(_ event: EKEvent) throws {
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            event.rollback()
            throw error
        }
    }

    private func save(_ reminder: EKReminder) throws {
        do {
            try store.save(reminder, commit: true)
        } catch {
            reminder.rollback()
            throw error
        }
    }

    private func state(of event: EKEvent) -> ActionCatalog.SavedItem {
        ActionCatalog.SavedItem(isEvent: true, title: event.title ?? "", date: event.startDate, end: event.endDate,
                                hasTime: !event.isAllDay, place: event.location,
                                collection: event.calendar?.calendarIdentifier ?? "")
    }

    private func state(of reminder: EKReminder, _ context: ToolContext) -> ActionCatalog.SavedItem {
        let due = dueDate(of: reminder, context)
        return ActionCatalog.SavedItem(isEvent: false, title: reminder.title ?? "", date: due?.date,
                                       hasTime: due?.hasTime ?? false,
                                       collection: reminder.calendar?.calendarIdentifier ?? "")
    }

    // MARK: - Undo

    private func addUndo(_ undo: Undo) -> UndoToken {
        undoCount += 1
        let id = "u\(undoCount)"
        undos[id] = undo
        return UndoToken(provider: identifier, id: id)
    }

    public func undoneName(_ token: UndoToken, language: SpeechLanguage) async -> String? {
        switch undos[token.id] {
        case nil: nil
        case .delete(.event)?: ActionPhrases.undoneName(.event, language)
        case .delete(.reminder)?: ActionPhrases.undoneName(.reminder, language)
        case .restore?: ActionPhrases.undoneName(.change, language)
        case .recreate?: ActionPhrases.undoneName(.deletion, language)
        }
    }

    public func undo(_ token: UndoToken, context: ToolContext) async throws -> String {
        guard let undo = undos.removeValue(forKey: token.id) else { return ActionPhrases.cannotUndo(context.language) }
        switch undo {
        case .delete(.event(let id)):
            if let event = store.event(withIdentifier: id) { try store.remove(event, span: .thisEvent, commit: true) }
            forget(id)
            return ActionPhrases.undone(.event, context.language)
        case .delete(.reminder(let id)):
            if let reminder = store.calendarItem(withIdentifier: id) as? EKReminder { try store.remove(reminder, commit: true) }
            forget(id)
            return ActionPhrases.undone(.reminder, context.language)
        case .restore(.event(let id), let before):
            if let event = store.event(withIdentifier: id) {
                event.title = before.title
                event.location = before.location
                event.isAllDay = before.allDay
                if let start = before.start, let end = before.end {
                    event.startDate = start
                    event.endDate = end
                }
                // Moved to another calendar by the change: back to its own (and maybe to another identifier again).
                if let calendar = before.calendar.flatMap({ store.calendar(withIdentifier: $0) }),
                   calendar.calendarIdentifier != event.calendar?.calendarIdentifier
                {
                    event.calendar = calendar
                }
                try save(event)
                _ = reread(event, id: id)
            }
            return ActionPhrases.undone(.change, context.language)
        case .recreate(let reference, .event, let before):
            let event = EKEvent(eventStore: store)
            event.title = before.title
            event.location = before.location
            event.isAllDay = before.allDay
            if let start = before.start, let end = before.end {
                event.startDate = start
                event.endDate = end
            }
            event.calendar = before.calendar.flatMap { store.calendar(withIdentifier: $0) } ?? store.defaultCalendarForNewEvents
            try store.save(event, span: .thisEvent, commit: true)
            created[reference] = .event(event.eventIdentifier)
            lastCreated = reference
            return ActionPhrases.undone(.change, context.language)
        case .recreate(let reference, .reminder, let before):
            let reminder = EKReminder(eventStore: store)
            reminder.title = before.title
            reminder.dueDateComponents = before.due
            before.alarmDates.forEach { reminder.addAlarm(EKAlarm(absoluteDate: $0)) }
            reminder.calendar = before.calendar.flatMap { store.calendar(withIdentifier: $0) }
                ?? store.defaultCalendarForNewReminders()
            try store.save(reminder, commit: true)
            created[reference] = .reminder(reminder.calendarItemIdentifier)
            lastCreated = reference
            return ActionPhrases.undone(.change, context.language)
        case .restore(.reminder(let id), let before):
            if let reminder = store.calendarItem(withIdentifier: id) as? EKReminder {
                reminder.title = before.title
                reminder.dueDateComponents = before.due
                reminder.alarms?.forEach { reminder.removeAlarm($0) }
                before.alarmDates.forEach { reminder.addAlarm(EKAlarm(absoluteDate: $0)) }
                if let list = before.calendar.flatMap({ store.calendar(withIdentifier: $0) }),
                   list.calendarIdentifier != reminder.calendar?.calendarIdentifier
                {
                    reminder.calendar = list
                }
                try save(reminder)
                _ = reread(reminder, id: id)
            }
            return ActionPhrases.undone(.change, context.language)
        }
    }

    private func forget(_ identifier: String) {
        for (reference, item) in created {
            switch item {
            case .event(let id), .reminder(let id):
                if id == identifier { created[reference] = nil }
            }
        }
        if let lastCreated, created[lastCreated] == nil { self.lastCreated = nil }
    }

    // MARK: - Calendars and lists

    /// The calendar for an event: the one named (a creation's, or the one a change moves it to), else the default one.
    /// With the test calendar, always that one: a change then leaves the event in it. `current`: the event's own, which a
    /// change names to leave it there.
    private func eventCalendar(named name: String?, current: EKCalendar? = nil, context: ToolContext) throws -> EKCalendar {
        if let testCollection { return try collection(.event, named: testCollection) }
        if let name { return try find(name, .event, current: current, context: context) }
        guard let calendar = store.defaultCalendarForNewEvents else {
            throw ToolRefusal(forModel: "Aucun calendrier par défaut.", spoken: ActionPhrases.saveFailed(context.language),
                              retryable: false)
        }
        return calendar
    }

    /// The list for a reminder, as `eventCalendar` finds an event's calendar.
    private func reminderList(named name: String?, current: EKCalendar? = nil, context: ToolContext) throws -> EKCalendar {
        if let testCollection { return try collection(.reminder, named: testCollection) }
        if let name { return try find(name, .reminder, current: current, context: context) }
        guard let list = store.defaultCalendarForNewReminders() else {
            throw ToolRefusal(forModel: "Aucune liste de rappels par défaut.",
                              spoken: ActionPhrases.saveFailed(context.language), retryable: false)
        }
        return list
    }

    /// A calendar or a list the item can be saved in (of its kind, not read-only), by its name compared without case or
    /// accents ("Maison" = "maison"), in every account; refused when there is none.
    private func find(_ name: String, _ type: EKEntityType, current: EKCalendar?, context: ToolContext) throws -> EKCalendar {
        let writable = store.calendars(for: type).filter(\.allowsContentModifications)
        let names = writable.map(\.title)
        let own = current.flatMap { current in writable.firstIndex { $0.calendarIdentifier == current.calendarIdentifier } }
        guard let index = ActionCatalog.collectionIndex(named: name, among: names, current: own) else {
            throw ActionCatalog.unknownCollection(name, event: type == .event, names: names, context: context)
        }
        return writable[index]
    }

    /// The names of the calendars (`.event`) or the lists an item of that kind can be saved in.
    private func writable(_ type: EKEntityType) -> [String] {
        store.calendars(for: type).filter(\.allowsContentModifications).map(\.title)
    }

    /// The test calendar or list, created next to the default one (iCloud, usually) the first time.
    private func collection(_ type: EKEntityType, named name: String) throws -> EKCalendar {
        if let existing = store.calendars(for: type).first(where: { $0.title == name }) { return existing }
        let calendar = EKCalendar(for: type, eventStore: store)
        calendar.title = name
        let reference = type == .event ? store.defaultCalendarForNewEvents : store.defaultCalendarForNewReminders()
        guard let source = reference?.source ?? store.sources.first(where: { $0.sourceType == .local }) else {
            throw ToolRefusal(forModel: "Aucun compte de calendrier.", spoken: "", retryable: false)
        }
        calendar.source = source
        try store.saveCalendar(calendar, commit: true)
        DebugLog.log("calendar: created the \(type == .event ? "calendar" : "list") “\(name)” in \(source.title)")
        return calendar
    }

    // MARK: - Helpers

    private func components(_ date: Date, hasTime: Bool, _ context: ToolContext) -> DateComponents {
        var components = context.calendar.dateComponents(
            hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day], from: date)
        components.calendar = Calendar(identifier: .gregorian)
        if hasTime { components.timeZone = context.timeZone }
        return components
    }

    private func dueDate(of reminder: EKReminder, _ context: ToolContext) -> (date: Date, hasTime: Bool)? {
        guard let components = reminder.dueDateComponents else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = components.timeZone ?? context.timeZone
        return calendar.date(from: components).map { ($0, components.hour != nil) }
    }

    private func snapshot(_ event: EKEvent) -> Snapshot {
        Snapshot(calendar: event.calendar?.calendarIdentifier, title: event.title, start: event.startDate,
                 end: event.endDate, allDay: event.isAllDay, location: event.location)
    }

    private func snapshot(_ reminder: EKReminder) -> Snapshot {
        Snapshot(calendar: reminder.calendar?.calendarIdentifier, title: reminder.title, due: reminder.dueDateComponents,
                 alarmDates: reminder.alarms?.compactMap(\.absoluteDate) ?? [])
    }

    private func describe(_ event: EKEvent, reference: String?, _ context: ToolContext) -> JSONValue {
        var fields: [String: JSONValue] = [
            "titre": .string(event.title ?? ""),
            "debut": .string(LocalDateTime.format(event.startDate, in: context.timeZone, withTime: !event.isAllDay)),
            "fin": .string(LocalDateTime.format(event.endDate, in: context.timeZone, withTime: !event.isAllDay)),
        ]
        if let reference { fields["id"] = .string(reference) }
        if event.isAllDay { fields["journee_entiere"] = true }
        if let location = event.location, !location.isEmpty { fields["lieu"] = .string(location) }
        if reference != nil, let calendar = event.calendar?.title { fields["calendrier"] = .string(calendar) }
        return .object(fields)
    }

    private func describe(_ reminder: EKReminder, reference: String, _ context: ToolContext) -> JSONValue {
        var fields: [String: JSONValue] = ["id": .string(reference), "titre": .string(reminder.title ?? "")]
        if let due = dueDate(of: reminder, context) {
            fields["echeance"] = .string(LocalDateTime.format(due.date, in: context.timeZone, withTime: due.hasTime))
        }
        if let list = reminder.calendar?.title { fields["liste"] = .string(list) }
        return .object(fields)
    }
}
