// nextevent: próximos eventos del Calendario de macOS (EventKit), para el modo uni de la barra.
// Salida: una línea por evento de las próximas `horas` (default 18), sin los de todo el día:
//   <inicio epoch>\t<fin epoch>\t<título>\t<lugar>
// La primera vez macOS pide permiso de Calendario (a sketchybar, que es quien lo ejecuta).
import EventKit
import Foundation

let hours = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 18 : 18
let store = EKEventStore()
let sem = DispatchSemaphore(value: 0)
var granted = false
if #available(macOS 14.0, *) {
    store.requestFullAccessToEvents { ok, _ in granted = ok; sem.signal() }
} else {
    store.requestAccess(to: .event) { ok, _ in granted = ok; sem.signal() }
}
sem.wait()
guard granted else { FileHandle.standardError.write("sin permiso de Calendario\n".data(using: .utf8)!); exit(3) }
let now = Date()
let pred = store.predicateForEvents(withStart: now.addingTimeInterval(-3 * 3600),
                                    end: now.addingTimeInterval(hours * 3600), calendars: nil)
for e in store.events(matching: pred).sorted(by: { $0.startDate < $1.startDate }) {
    if e.isAllDay || e.endDate < now { continue }
    let clean = { (s: String?) in (s ?? "").replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
    print("\(Int(e.startDate.timeIntervalSince1970))\t\(Int(e.endDate.timeIntervalSince1970))\t\(clean(e.title))\t\(clean(e.location))")
}
