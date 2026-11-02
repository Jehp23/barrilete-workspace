// addclasses: carga el horario de la facultad en el Calendario de macOS (calendario "Facultad"),
// como eventos semanales con aviso 15 min antes. Lee TSV por stdin:
//   <día 1=lun..5=vie>\t<HH:MM inicio>\t<HH:MM fin>\t<materia>\t<aula>
// Uso: addclasses <desde AAAA-MM-DD> <hasta AAAA-MM-DD> < horario.tsv
// Si el calendario "Facultad" ya existe, borra sus eventos recurrentes futuros y los vuelve a crear.
import EventKit
import Foundation

let args = CommandLine.arguments
guard args.count == 3 else { print("uso: addclasses <desde> <hasta> < horario.tsv"); exit(64) }
let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"; df.timeZone = .current
guard let from = df.date(from: args[1]), let until = df.date(from: args[2]) else { print("fechas inválidas"); exit(64) }

let store = EKEventStore()
let sem = DispatchSemaphore(value: 0)
var ok = false
if #available(macOS 14.0, *) { store.requestFullAccessToEvents { g, _ in ok = g; sem.signal() } }
else { store.requestAccess(to: .event) { g, _ in ok = g; sem.signal() } }
sem.wait()
guard ok else { print("sin permiso de Calendario"); exit(3) }

var cal = store.calendars(for: .event).first { $0.title == "Facultad" }
if cal == nil {
    let c = EKCalendar(for: .event, eventStore: store)
    c.title = "Facultad"
    c.source = store.defaultCalendarForNewEvents?.source ?? store.sources.first { $0.sourceType == .local }
    c.cgColor = CGColor(red: 0.80, green: 0.65, blue: 0.97, alpha: 1)
    try store.saveCalendar(c, commit: true)
    cal = c
} else {
    // Recargar: borrar la serie de cada evento recurrente que ya estaba
    let old = store.events(matching: store.predicateForEvents(withStart: from, end: until, calendars: [cal!]))
    var seen = Set<String>()
    for e in old where e.hasRecurrenceRules && !seen.contains(e.calendarItemIdentifier) {
        seen.insert(e.calendarItemIdentifier)
        try? store.remove(e, span: .futureEvents, commit: false)
    }
    try store.commit()
}

let cg = Calendar.current
var n = 0
while let line = readLine() {
    let p = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    guard p.count >= 4, let wd = Int(p[0]) else { continue }
    let hm = { (s: String) -> (Int, Int) in let x = s.split(separator: ":").compactMap { Int($0) }; return (x[0], x[1]) }
    let (sh, sm) = hm(p[1]), (eh, em) = hm(p[2])
    // Primer día de la semana pedido (1=lun) a partir de "desde"
    var day = from
    while cg.component(.weekday, from: day) != (wd % 7) + 1 { day = cg.date(byAdding: .day, value: 1, to: day)! }
    let ev = EKEvent(eventStore: store)
    ev.calendar = cal
    ev.title = p[3]
    ev.location = p.count > 4 && !p[4].isEmpty ? p[4] : nil
    ev.startDate = cg.date(bySettingHour: sh, minute: sm, second: 0, of: day)!
    ev.endDate = cg.date(bySettingHour: eh, minute: em, second: 0, of: day)!
    ev.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: EKRecurrenceEnd(end: until)))
    ev.addAlarm(EKAlarm(relativeOffset: -15 * 60))
    try store.save(ev, span: .futureEvents, commit: false)
    n += 1
}
try store.commit()
print("\(n) materias cargadas en el calendario Facultad (semanales hasta \(args[2]))")
