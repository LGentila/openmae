import CoreLocation
import Foundation
import MapKit
import VoiceCore

/// Where the Mac is, from CoreLocation (Wi-Fi networks around it): "here" for the weather and the travel times. macOS
/// asks the user once (the app's location entitlement and its usage description, in App/project.yml). Kept for ten
/// minutes; nil when the location is off, refused, or not found in time.
public actor MacLocation: HereLocating {
    private var last: (place: Place, at: Date)?

    public init() {}

    public func willAsk() async -> Bool {
        await MainActor.run { Self.manager.authorizationStatus == .notDetermined }
    }

    public func here() async -> Place? {
        if let last, Date().timeIntervalSince(last.at) < 600 { return last.place }
        guard let location = await Self.currentLocation() else { return nil }
        let town = await Self.townName(of: location)
        let place = Place(name: town ?? "ta position", latitude: location.coordinate.latitude,
                          longitude: location.coordinate.longitude)
        last = (place, Date())
        DebugLog.log("location found\(town == nil ? "" : " (a town's name too)")")
        return place
    }

    /// Asks macOS for the location the first time (its question shows the app's usage description), and keeps the
    /// question up while the user answers.
    @MainActor private static let manager = CLLocationManager()

    /// One location, or nil: refused, off, or nothing within 30 seconds (time enough to answer macOS's question).
    private static func currentLocation() async -> CLLocation? {
        await MainActor.run {
            if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        }
        return await withTaskGroup(of: CLLocation?.self) { group in
            group.addTask {
                do {
                    for try await update in CLLocationUpdate.liveUpdates() {
                        if let location = update.location { return location }
                        if update.authorizationDenied || update.authorizationDeniedGlobally
                            || update.authorizationRestricted
                        {
                            DebugLog.log("location refused or off")
                            return nil
                        }
                    }
                } catch {
                    DebugLog.log("location failed: \(error)")
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(30))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func townName(of location: CLLocation) async -> String? {
        let placemarks = try? await CLGeocoder().reverseGeocodeLocation(location, preferredLocale: Locale(identifier: "fr_FR"))
        return placemarks?.first?.locality
    }
}

/// Travel times from Apple's maps (MapKit: the place found by a local search, then an ETA request, by car with the
/// traffic at that time or by public transport). Free, no key; the places and the coordinates go to Apple.
public struct MapKitTravel: TravelEstimating {
    public init() {}

    public func estimate(to destination: String, from origin: String?, here: Place?, mode: TravelMode, arriveBy: Date?)
        async throws -> TravelEstimate
    {
        let start: MKMapItem
        if let origin {
            start = try await Self.find(origin, near: here)
        } else if let here {
            start = Self.item(at: here)
        } else {
            throw SourceError.notFound
        }
        let around = here ?? Self.place(of: start)
        let end = try await Self.find(destination, near: around)
        let request = MKDirections.Request()
        request.source = start
        request.destination = end
        request.transportType = mode == .car ? .automobile : .transit
        if let arriveBy { request.arrivalDate = arriveBy } else { request.departureDate = Date() }
        let eta: MKDirections.ETAResponse
        do {
            eta = try await MKDirections(request: request).calculateETA()
        } catch let error as MKError where error.code == .directionsNotFound {
            throw SourceError.unexpected
        } catch let error as MKError where error.code == .placemarkNotFound {
            throw SourceError.notFound
        } catch {
            DebugLog.log("travel ETA failed: \(error)")
            throw SourceError.unreachable
        }
        return TravelEstimate(origin: origin.flatMap { _ in start.name }, destination: end.name ?? destination,
                              mode: mode, seconds: eta.expectedTravelTime, meters: eta.distance,
                              departure: eta.expectedDepartureDate, arrival: eta.expectedArrivalDate,
                              arriveBy: arriveBy != nil)
    }

    /// The place the user's words stand for, within about 100 km of `near`: a local search with the words, and one
    /// without their article when they have one (at the same time), then the best of what they found
    /// (`TravelTimeCatalog.bestPlace`).
    static func find(_ words: String, near: Place?) async throws -> MKMapItem {
        let bare = TravelTimeCatalog.withoutArticle(words)
        async let asSaid = search(words, near: near)
        async let withoutArticle = bare == words || bare.isEmpty ? [] : search(bare, near: near)
        let found = try await asSaid + withoutArticle
        let candidates = found.map { (name: $0.name ?? "", isPointOfInterest: $0.pointOfInterestCategory != nil) }
        guard let best = TravelTimeCatalog.bestPlace(candidates, for: words) else { throw SourceError.notFound }
        return found[best]
    }

    /// The first places a local search finds (none: an empty list).
    private static func search(_ words: String, near: Place?) async throws -> [MKMapItem] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = words
        if let near {
            request.region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: near.latitude, longitude: near.longitude),
                latitudinalMeters: 100_000, longitudinalMeters: 100_000)
        }
        do {
            return Array(try await MKLocalSearch(request: request).start().mapItems.prefix(5))
        } catch let error as MKError where error.code == .placemarkNotFound {
            return []
        } catch {
            DebugLog.log("place search failed: \(error)")
            throw SourceError.unreachable
        }
    }

    static func item(at place: Place) -> MKMapItem {
        let coordinate = CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
        if #available(macOS 26, *) {
            return MKMapItem(location: CLLocation(latitude: place.latitude, longitude: place.longitude), address: nil)
        }
        return MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
    }

    static func place(of item: MKMapItem) -> Place {
        let coordinate: CLLocationCoordinate2D
        if #available(macOS 26, *) {
            coordinate = item.location.coordinate
        } else {
            coordinate = item.placemark.coordinate
        }
        return Place(name: item.name ?? "", latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}
