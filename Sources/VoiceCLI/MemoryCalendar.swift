// The app's reminders and calendar for voice-cli dialogue-bench: the same checks, results and sentences as
// `CalendarTools` (VoiceEngineApple), on items kept in memory instead of EventKit. One calendar, « Maison », and one
// reminder list, « Rappels », both empty when a dialogue starts; a dialogue may have others (`use`).

import Foundation
import VoiceCore

actor MemoryCalendar: ToolProvider {
    nonisolated let identifier = "calendar"
    static let calendarName = "Maison"
    static let listName = "Rappels"

    private struct Item: Sendable {
        var isEvent: Bool
        var title: String
        /// An event's start, a reminder's due date (nil: none).
        var date: Date?
        var end: Date?
        /// An event at a time (not for the whole day), a reminder due at a time.
        var hasTime: Bool
        var place: String?
        /// Its calendar (an event's) or its list (a reminder's).
        var collection: String
    }

    /// The calendars and the reminder lists there are, the default one first.
    private var calendars = [calendarName]
    private var lists = [listName]

    /// Items created in this conversation, by the reference given to the model ("e1", "r2").
    private var items: [String: Item] = [:]
    private var lastCreated: String?
    private var eventCount = 0
    private var reminderCount = 0
    /// What "annule" puts back, by undo token: the item as it was before (nil: it did not exist).
    private var undos: [String: (reference: String, before: Item?)] = [:]
    private var undoCount = 0
    /// The calendar is named once per conversation, as in the app.
    private var calendarNamed = false
    /// As in the app: a creation just refused for a detail the user gives again (its moment, its calendar or its
    /// list), which a change of the last item, or of an item never created, makes instead.
    private var refusedCreation = RefusedCreation()
    /// Every item created, by reference, in order: what the bench checks a dialogue's goal against.
    private(set) var creations: [String] = []
    /// Every item changed or deleted, by its title as it was, in order: what the bench checks an item that a dialogue
    /// must leave as it was against.
    private(set) var touched: [String] = []

    func tools() -> [ToolSpec] { ActionCatalog.calendarTools }

    /// The calendars and the lists of the next conversations, the default one first (none: « Maison », « Rappels »).
    func use(calendars: [String]?, lists: [String]?) {
        self.calendars = calendars.flatMap { $0.isEmpty ? nil : $0 } ?? [Self.calendarName]
        self.lists = lists.flatMap { $0.isEmpty ? nil : $0 } ?? [Self.listName]
    }

    func check(_ call: ToolCall, context: ToolContext) throws {
        refusedCreation.checking(call)
        do {
            try ActionCatalog.check(refusedCreation.withRefusedDay(call, said: context.userSaid), context: context)
        } catch let refusal as ToolRefusal {
            refusedCreation.refused(completed(call, context), refusal)
            throw refusal
        }
    }

    /// As in the app: a creation whose call names no calendar or no list, with the one the user's words name, or the one
    /// of the same creation refused just before (`ActionCatalog.withCollectionSaid`); with an hour alone, that refused
    /// creation's day when its words left the hour open (`RefusedCreation.withRefusedDay`).
    private func completed(_ call: ToolCall, _ context: ToolContext) -> ToolCall {
        ActionCatalog.withCollectionSaid(refusedCreation.withRefusedDay(call, said: context.userSaid), context: context,
                                         again: refusedCreation.collection(before: call)) {
            $0 ? calendars : lists
        }
    }

    func resetConversation() {
        items = [:]
        lastCreated = nil
        undos = [:]
        calendarNamed = false
        refusedCreation.forget()
    }

    /// As in the app: a creation refused here (a calendar or a list that does not exist) is kept as one refused by
    /// `check` is.
    func perform(_ call: ToolCall, context: ToolContext) async throws -> ToolOutcome {
        do {
            return try await carryOut(call, context: context)
        } catch let refusal as ToolRefusal {
            refusedCreation.refused(completed(call, context), refusal)
            throw refusal
        }
    }

    private func carryOut(_ call: ToolCall, context: ToolContext) async throws -> ToolOutcome {
        switch call.name {
        case ActionCatalog.createEvent.name:
            let call = completed(call, context)
            let title = try ActionCatalog.title(call, context: context)
            let times = try ActionCatalog.eventTimes(call, context: context)
            let named = call.text("calendrier")
            let calendar = try collection(named, event: true, context)
            eventCount += 1
            let reference = "e\(eventCount)"
            let item = Item(isEvent: true, title: title, date: times.start, end: times.end, hasTime: !times.allDay,
                            place: call.text("lieu"), collection: calendar)
            let sayCalendar = named != nil || !calendarNamed
            calendarNamed = true
            return created(item, reference, spoken: ActionPhrases.eventCreated(
                title: title, start: times.start, end: times.end, allDay: times.allDay,
                calendarName: sayCalendar ? calendar : nil, context), context)
        case ActionCatalog.createReminder.name:
            let call = completed(call, context)
            let title = try ActionCatalog.title(call, context: context)
            let due = try ActionCatalog.reminderDue(call, context: context)
            let named = call.text("liste")
            let list = try collection(named, event: false, context)
            reminderCount += 1
            let reference = "r\(reminderCount)"
            let item = Item(isEvent: false, title: title, date: due?.date, hasTime: due?.hasTime ?? false, collection: list)
            return created(item, reference, spoken: ActionPhrases.reminderCreated(
                title: title, due: due?.date, hasTime: due?.hasTime ?? false, listName: named != nil ? list : nil,
                context), context)
        case ActionCatalog.readAgenda.name:
            guard let (start, end) = try ActionCatalog.period(call, context: context, required: true) else {
                throw DateCheck.refusal(.missing, key: "quand", raw: "", context: context)
            }
            let events = items.values.filter { $0.isEvent && ($0.end ?? .distantFuture) > start && ($0.date ?? start) < end }
                .sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
            return ToolOutcome(
                spoken: ActionPhrases.agenda(events.map {
                    ActionPhrases.Item(title: $0.title, date: max($0.date ?? start, start), hasTime: $0.hasTime)
                }, from: start, to: end, context),
                forModel: ["nombre": .int(events.count),
                           "evenements": .array(events.prefix(12).map { describe($0, reference: nil, context) })])
        case ActionCatalog.listReminders.name:
            let period = try ActionCatalog.period(call, context: context, required: false)
            // As the app: a period that has already begun also takes what is still to do from before it.
            let from = period.flatMap { $0.0 > context.now ? $0.0 : nil }
            let reminders = items.values.filter { item in
                guard !item.isEvent else { return false }
                guard let end = period?.1 else { return true }
                guard let due = item.date else { return false }
                return due < end && (from.map { due >= $0 } ?? true)
            }.sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
            return ToolOutcome(
                spoken: ActionPhrases.reminders(reminders.map { ActionPhrases.Item(title: $0.title, date: $0.date,
                                                                                   hasTime: $0.hasTime) },
                                                from: period?.0, to: period?.1, context),
                forModel: ["nombre": .int(reminders.count),
                           "rappels": .array(reminders.prefix(12).map { item in
                               ["titre": .string(item.title),
                                "echeance": item.date.map {
                                    .string(LocalDateTime.format($0, in: context.timeZone, withTime: item.hasTime))
                                } ?? .null]
                           })])
        case ActionCatalog.changeItem.name:
            // As in the app: the item whose creation was just refused, named as the last item or by an id that names
            // none, is created with what the change gives.
            if let creation = refusedCreation.creation(insteadOf: call, said: context.userSaid, exists: { items[$0] != nil }) {
                return try await perform(creation, context: context)
            }
            let (reference, item) = try referenced(call, context)
            var changed = item
            if let title = call.text("titre") { changed.title = title }
            if item.isEvent {
                if let place = call.text("lieu") { changed.place = place }
                let start = item.date ?? context.now
                if let times = try ActionCatalog.changedEvent(call, start: start, end: item.end ?? start.addingTimeInterval(3600),
                                                             allDay: !item.hasTime, context: context)
                {
                    (changed.date, changed.end, changed.hasTime) = (times.start, times.end, !times.allDay)
                }
            } else {
                let due = item.date.map { (date: $0, hasTime: item.hasTime) }
                if let moved = try ActionCatalog.changedDue(call, due: due, context: context) {
                    (changed.date, changed.hasTime) = (moved.date, moved.hasTime)
                }
            }
            items[reference] = changed
            touched.append(item.title)
            let moved = changed.date != item.date || changed.hasTime != item.hasTime
            let spoken = item.isEvent
                ? ActionPhrases.eventChanged(title: changed.title, start: changed.date ?? context.now,
                                             end: changed.end ?? context.now, allDay: !changed.hasTime, moved: moved, context)
                : ActionPhrases.reminderChanged(title: changed.title, due: changed.date, hasTime: changed.hasTime,
                                                moved: moved, context)
            return ToolOutcome(spoken: spoken, forModel: describe(changed, reference: reference, context),
                               undo: addUndo(reference, before: item))
        case ActionCatalog.deleteItem.name:
            let (reference, item) = try referenced(call, context)
            items[reference] = nil
            touched.append(item.title)
            if lastCreated == reference { lastCreated = nil }
            return ToolOutcome(spoken: ActionPhrases.deleted(event: item.isEvent, title: item.title, context.language),
                               forModel: ["id": .string(reference), "statut": "supprimé"],
                               undo: addUndo(reference, before: item))
        default:
            throw ToolRefusal(forModel: "Outil inconnu : \(call.name).", spoken: ActionPhrases.notUnderstood(context.language))
        }
    }

    func undoneName(_ token: UndoToken, language: SpeechLanguage) -> String? {
        guard let undo = undos[token.id] else { return nil }
        // A change or a deletion: the item as it was comes back.
        if undo.before != nil { return ActionPhrases.undoneName(items[undo.reference] == nil ? .deletion : .change, language) }
        return items[undo.reference].map { ActionPhrases.undoneName($0.isEvent ? .event : .reminder, language) }
    }

    func undo(_ token: UndoToken, context: ToolContext) throws -> String {
        guard let undo = undos.removeValue(forKey: token.id) else { return ActionPhrases.cannotUndo(context.language) }
        let current = items[undo.reference]
        items[undo.reference] = undo.before
        if undo.before != nil { lastCreated = undo.reference }
        guard undo.before == nil, let current else { return ActionPhrases.undone(.change, context.language) }
        return ActionPhrases.undone(current.isEvent ? .event : .reminder, context.language)
    }

    private func created(_ item: Item, _ reference: String, spoken: String, _ context: ToolContext) -> ToolOutcome {
        items[reference] = item
        lastCreated = reference
        creations.append(reference)
        return ToolOutcome(spoken: spoken, forModel: describe(item, reference: reference, context),
                           undo: addUndo(reference, before: nil))
    }

    /// The calendar (`event`) or the list a call names, among this conversation's, found as `CalendarTools` finds it
    /// (whatever the case and accents, else one whose name contains it or is contained in it); none named: the default
    /// one. Refused as in the app when none has that name.
    private func collection(_ named: String?, event: Bool, _ context: ToolContext) throws -> String {
        let names = event ? calendars : lists
        guard let named else { return names[0] }
        guard let index = ActionCatalog.collectionMatch(named, among: names) else {
            var refusal = event
                ? ToolRefusal(forModel: "Aucun calendrier modifiable ne s'appelle « \(named) ». Calendriers : "
                                  + names.joined(separator: ", ") + ".",
                              spoken: ActionPhrases.unknownCalendar(named, context.language))
                : ToolRefusal(forModel: "Aucune liste de rappels ne s'appelle « \(named) ». Listes : "
                                  + names.joined(separator: ", ") + ".",
                              spoken: ActionPhrases.unknownList(named, context.language))
            refusal.detailGivenAgain = true
            throw refusal
        }
        return names[index]
    }

    /// The item a call refers to: "dernier", or a reference given earlier ("e1").
    private func referenced(_ call: ToolCall, _ context: ToolContext) throws -> (String, Item) {
        let reference = call.text("reference") ?? "dernier"
        let key = ActionCatalog.meansLastItem(reference) ? lastCreated : reference
        guard let key, let item = items[key] else {
            throw ToolRefusal(forModel: "Aucun élément « \(reference) » créé dans cette conversation : seuls ceux-là "
                              + "peuvent être modifiés ou supprimés.",
                              spoken: ActionPhrases.nothingToChange(context.language))
        }
        return (key, item)
    }

    private func addUndo(_ reference: String, before: Item?) -> UndoToken {
        undoCount += 1
        let id = "u\(undoCount)"
        undos[id] = (reference, before)
        return UndoToken(provider: identifier, id: id)
    }

    /// As `CalendarTools` describes an item to the model.
    private func describe(_ item: Item, reference: String?, _ context: ToolContext) -> JSONValue {
        let timeZone = context.timeZone
        var fields: [String: JSONValue] = ["titre": .string(item.title)]
        if let reference { fields["id"] = .string(reference) }
        if item.isEvent {
            if let start = item.date { fields["debut"] = .string(LocalDateTime.format(start, in: timeZone, withTime: item.hasTime)) }
            if let end = item.end { fields["fin"] = .string(LocalDateTime.format(end, in: timeZone, withTime: item.hasTime)) }
            if !item.hasTime { fields["journee_entiere"] = true }
            if let place = item.place, !place.isEmpty { fields["lieu"] = .string(place) }
            if reference != nil { fields["calendrier"] = .string(item.collection) }
        } else {
            if let due = item.date { fields["echeance"] = .string(LocalDateTime.format(due, in: timeZone, withTime: item.hasTime)) }
            fields["liste"] = .string(item.collection)
        }
        return .object(fields)
    }
}
