//
//  Geocoder.swift
//  re.mind
//
//  Created by Raul Sanchez on 9/3/26.
//

import Foundation
import CoreLocation
import MapKit

enum PlaceGeocodingError: Error, LocalizedError {
    case emptyPlace
    case notFound
    case underlying(Error)

    var errorDescription: String? {
        switch self {
        case .emptyPlace:
            return "The place string is empty."
        case .notFound:
            return "No location could be resolved for the provided place."
        case .underlying(let error):
            return error.localizedDescription
        }
    }
}

struct PlaceResolutionResult {
    let originalQuery: String
    let displayName: String
    let geoLocation: GeoLocation
}

final class PlaceGeocodingService {

    static let shared = PlaceGeocodingService()

    private let geocoder = CLGeocoder()

    private init() {}

    func resolve(place: String) async throws -> PlaceResolutionResult {
        let query = place.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !query.isEmpty else {
            throw PlaceGeocodingError.emptyPlace
        }

        if let result = try await resolveWithCLGeocoder(query: query) {
            return result
        }

        if let result = try await resolveWithMKLocalSearch(query: query) {
            return result
        }

        throw PlaceGeocodingError.notFound
    }
}

private extension PlaceGeocodingService {

    func resolveWithCLGeocoder(query: String) async throws -> PlaceResolutionResult? {
        do {
            let placemarks = try await geocoder.geocodeAddressString(query)

            guard let placemark = placemarks.first,
                  let location = placemark.location else {
                return nil
            }

            let displayName = buildDisplayName(from: placemark, fallback: query)

            return PlaceResolutionResult(
                originalQuery: query,
                displayName: displayName,
                geoLocation: GeoLocation(
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    resolvedAddress: displayName
                )
            )
        } catch {
            return nil
        }
    }

    func buildDisplayName(from placemark: CLPlacemark, fallback: String) -> String {
        let components = [
            placemark.name,
            placemark.thoroughfare,
            placemark.subThoroughfare,
            placemark.locality,
            placemark.administrativeArea,
            placemark.country
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

        let unique = orderedUnique(components)
        return unique.isEmpty ? fallback : unique.joined(separator: ", ")
    }

    func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for value in values {
            let key = value.lowercased()
            if !seen.contains(key) {
                seen.insert(key)
                result.append(value)
            }
        }

        return result
    }
}

private extension PlaceGeocodingService {

    func resolveWithMKLocalSearch(query: String) async throws -> PlaceResolutionResult? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query

        let search = MKLocalSearch(request: request)

        do {
            let response = try await search.start()

            guard let item = response.mapItems.first else {
                return nil
            }

            let coordinate = item.placemark.coordinate
            let displayName = buildDisplayName(from: item, fallback: query)

            return PlaceResolutionResult(
                originalQuery: query,
                displayName: displayName,
                geoLocation: GeoLocation(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude,
                    resolvedAddress: displayName
                )
            )
        } catch {
            throw PlaceGeocodingError.underlying(error)
        }
    }

    func buildDisplayName(from mapItem: MKMapItem, fallback: String) -> String {
        let placemark = mapItem.placemark

        let components = [
            mapItem.name,
            placemark.title,
            placemark.locality,
            placemark.administrativeArea,
            placemark.country
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

        let unique = orderedUnique(components)
        return unique.isEmpty ? fallback : unique.joined(separator: ", ")
    }
}
