import CoreLocation
import Foundation
import Observation

/// CLLocationManager wrapper. When-in-use for distances and the user dot; Always
/// (with background updates) only when "Near me now" alerts are enabled.
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    var location: CLLocation?
    var authorization: CLAuthorizationStatus = .notDetermined
    /// Called on every location update (used to report `last_location` for near-me alerts).
    @ObservationIgnored var onUpdate: ((CLLocation) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 50
        manager.pausesLocationUpdatesAutomatically = true
        authorization = manager.authorizationStatus
    }

    var isAuthorized: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }

    func requestWhenInUse() {
        if authorization == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else if isAuthorized {
            manager.startUpdatingLocation()
        }
    }

    func requestAlways() {
        manager.requestAlwaysAuthorization()
    }

    /// Background location updates for "Near me now". Requires the `location`
    /// background mode (Info.plist) and Always authorization to be useful.
    func setBackgroundUpdates(_ on: Bool) {
        manager.allowsBackgroundLocationUpdates = on && authorization == .authorizedAlways
        manager.showsBackgroundLocationIndicator = false
        if on {
            manager.startMonitoringSignificantLocationChanges()
        } else {
            manager.stopMonitoringSignificantLocationChanges()
        }
    }

    func distance(to coordinate: CLLocationCoordinate2D) -> CLLocationDistance? {
        guard let location else { return nil }
        return location.distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
    }

    /// "0.6 mi", "12 mi" or "—".
    func distanceText(to coordinate: CLLocationCoordinate2D) -> String {
        Format.distance(meters: distance(to: coordinate))
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        if isAuthorized {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        location = last
        onUpdate?(last)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Keep the last fix; distances show "—" until we get one.
    }
}
