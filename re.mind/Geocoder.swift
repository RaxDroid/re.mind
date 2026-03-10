//
//  Geocoder.swift
//  re.mind
//

import Foundation
import MapKit

enum PlaceGeocodingError: Error, LocalizedError, Equatable {
    case emptyQuery
    case noResults
    case searchFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyQuery:
            return "The place query is empty."
        case .noResults:
            return "No matching places were found."
        case .searchFailed(let message):
            return "Place search failed: \(message)"
        }
    }
}

struct PlaceResolutionResult: Equatable {
    let originalQuery: String
    let displayName: String
    let geoLocation: GeoLocation
}

@MainActor
final class PlaceGeocodingService {

    static let shared = PlaceGeocodingService()

    private init() {}

    func resolve(place: String) async throws -> PlaceResolutionResult {
        let query = sanitize(place)

        guard !query.isEmpty else {
            throw PlaceGeocodingError.emptyQuery
        }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query

        let search = MKLocalSearch(request: request)

        do {
            let response = try await search.start()

            guard let bestMatch = bestMapItem(from: response.mapItems, originalQuery: query) else {
                throw PlaceGeocodingError.noResults
            }

            let coordinate = bestMatch.location.coordinate
            let displayName = buildDisplayName(from: bestMatch, fallback: query)

            return PlaceResolutionResult(
                originalQuery: query,
                displayName: displayName,
                geoLocation: GeoLocation(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude,
                    resolvedAddress: displayName
                )
            )
        } catch let error as PlaceGeocodingError {
            throw error
        } catch {
            throw PlaceGeocodingError.searchFailed(error.localizedDescription)
        }
    }

    func resolve(
        place: String,
        near region: MKCoordinateRegion
    ) async throws -> PlaceResolutionResult {
        let query = sanitize(place)

        guard !query.isEmpty else {
            throw PlaceGeocodingError.emptyQuery
        }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = region
        request.regionPriority = .required

        let search = MKLocalSearch(request: request)

        do {
            let response = try await search.start()

            guard let bestMatch = bestMapItem(from: response.mapItems, originalQuery: query) else {
                throw PlaceGeocodingError.noResults
            }

            let coordinate = bestMatch.location.coordinate
            let displayName = buildDisplayName(from: bestMatch, fallback: query)

            return PlaceResolutionResult(
                originalQuery: query,
                displayName: displayName,
                geoLocation: GeoLocation(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude,
                    resolvedAddress: displayName
                )
            )
        } catch let error as PlaceGeocodingError {
            throw error
        } catch {
            throw PlaceGeocodingError.searchFailed(error.localizedDescription)
        }
    }
}

private extension PlaceGeocodingService {

    func sanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func bestMapItem(from items: [MKMapItem], originalQuery: String) -> MKMapItem? {
        guard !items.isEmpty else { return nil }

        let normalizedQuery = normalizeForComparison(originalQuery)

        return items.max { lhs, rhs in
            score(lhs, against: normalizedQuery) < score(rhs, against: normalizedQuery)
        }
    }

    func score(_ item: MKMapItem, against normalizedQuery: String) -> Int {
        var total = 0

        let name = normalizeForComparison(item.name ?? "")
        let display = normalizeForComparison(buildDisplayName(from: item, fallback: ""))

        if !name.isEmpty {
            if name == normalizedQuery { total += 1000 }
            if name.contains(normalizedQuery) { total += 400 }
            if normalizedQuery.contains(name) { total += 250 }
        }

        if !display.isEmpty {
            if display == normalizedQuery { total += 700 }
            if display.contains(normalizedQuery) { total += 250 }
        }

        total += 100 // MKMapItem.location is available here in your SDK

        return total
    }

    func normalizeForComparison(_ text: String) -> String {
        text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_DO"))
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func buildDisplayName(from item: MKMapItem, fallback: String) -> String {
        var parts: [String] = []

        if let name = normalized(item.name) {
            parts.append(name)
        }

        if let address = item.address {
            if let short = normalized(address.shortAddress) {
                parts.append(short)
            }

            if let full = normalized(address.fullAddress) {
                parts.append(full)
            }
        }

        if #available(iOS 26.0, *) {
            if let representations = item.addressRepresentations {
                if let city = normalized(representations.cityWithContext) {
                    parts.append(city)
                }

                if let fullNoRegion = normalized(
                    representations.fullAddress(includingRegion: false, singleLine: true)
                ) {
                    parts.append(fullNoRegion)
                }

                if let fullWithRegion = normalized(
                    representations.fullAddress(includingRegion: true, singleLine: true)
                ) {
                    parts.append(fullWithRegion)
                }
            }
        }

        let unique = orderedUnique(parts)
        return unique.isEmpty ? fallback : unique.first ?? fallback
    }

    func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for value in values {
            let key = normalizeForComparison(value)
            if !key.isEmpty, !seen.contains(key) {
                seen.insert(key)
                result.append(value)
            }
        }

        return result
    }
}
