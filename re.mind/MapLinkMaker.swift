//
//  MapLinkMaker.swift
//  re.mind
//

import Foundation

enum MapsProvider {
    case appleMaps
    case googleMaps
    case waze
}

enum MapsLinkBuilder {

    // MARK: - Public: Search / Open Place

    static func url(for reminder: Reminder, provider: MapsProvider) -> URL? {
        if let geo = reminder.geolocation {
            return url(
                provider: provider,
                latitude: geo.latitude,
                longitude: geo.longitude,
                label: reminder.place ?? geo.resolvedAddress
            )
        }

        if let place = sanitized(reminder.place) {
            return url(provider: provider, placeQuery: place)
        }

        return nil
    }

    static func url(provider: MapsProvider, placeQuery: String) -> URL? {
        guard let query = sanitized(placeQuery) else { return nil }

        switch provider {
        case .appleMaps:
            return makeURL(
                base: "http://maps.apple.com/",
                queryItems: [
                    URLQueryItem(name: "q", value: query)
                ]
            )

        case .googleMaps:
            return makeURL(
                base: "https://www.google.com/maps/search/",
                queryItems: [
                    URLQueryItem(name: "api", value: "1"),
                    URLQueryItem(name: "query", value: query)
                ]
            )

        case .waze:
            return makeURL(
                base: "https://waze.com/ul",
                queryItems: [
                    URLQueryItem(name: "q", value: query),
                    URLQueryItem(name: "navigate", value: "yes")
                ]
            )
        }
    }

    static func url(
        provider: MapsProvider,
        latitude: Double,
        longitude: Double,
        label: String? = nil
    ) -> URL? {
        let coordinateString = coordinateText(latitude: latitude, longitude: longitude)
        let resolvedLabel = sanitized(label)

        switch provider {
        case .appleMaps:
            return makeURL(
                base: "http://maps.apple.com/",
                queryItems: [
                    URLQueryItem(name: "ll", value: coordinateString),
                    URLQueryItem(name: "q", value: resolvedLabel ?? coordinateString)
                ]
            )

        case .googleMaps:
            return makeURL(
                base: "https://www.google.com/maps/search/",
                queryItems: [
                    URLQueryItem(name: "api", value: "1"),
                    URLQueryItem(name: "query", value: coordinateString)
                ]
            )

        case .waze:
            return makeURL(
                base: "https://waze.com/ul",
                queryItems: [
                    URLQueryItem(name: "ll", value: coordinateString),
                    URLQueryItem(name: "navigate", value: "yes")
                ]
            )
        }
    }

    // MARK: - Public: Directions / Navigation

    static func directionsURL(for reminder: Reminder, provider: MapsProvider) -> URL? {
        if let geo = reminder.geolocation {
            return directionsURL(
                provider: provider,
                latitude: geo.latitude,
                longitude: geo.longitude
            )
        }

        if let place = sanitized(reminder.place) {
            return directionsURL(provider: provider, placeQuery: place)
        }

        return nil
    }

    static func directionsURL(provider: MapsProvider, placeQuery: String) -> URL? {
        guard let query = sanitized(placeQuery) else { return nil }

        switch provider {
        case .appleMaps:
            return makeURL(
                base: "http://maps.apple.com/",
                queryItems: [
                    URLQueryItem(name: "daddr", value: query),
                    URLQueryItem(name: "dirflg", value: "d")
                ]
            )

        case .googleMaps:
            return makeURL(
                base: "https://www.google.com/maps/dir/",
                queryItems: [
                    URLQueryItem(name: "api", value: "1"),
                    URLQueryItem(name: "destination", value: query),
                    URLQueryItem(name: "travelmode", value: "driving")
                ]
            )

        case .waze:
            return makeURL(
                base: "https://waze.com/ul",
                queryItems: [
                    URLQueryItem(name: "q", value: query),
                    URLQueryItem(name: "navigate", value: "yes")
                ]
            )
        }
    }

    static func directionsURL(
        provider: MapsProvider,
        latitude: Double,
        longitude: Double
    ) -> URL? {
        let coordinateString = coordinateText(latitude: latitude, longitude: longitude)

        switch provider {
        case .appleMaps:
            return makeURL(
                base: "http://maps.apple.com/",
                queryItems: [
                    URLQueryItem(name: "daddr", value: coordinateString),
                    URLQueryItem(name: "dirflg", value: "d")
                ]
            )

        case .googleMaps:
            return makeURL(
                base: "https://www.google.com/maps/dir/",
                queryItems: [
                    URLQueryItem(name: "api", value: "1"),
                    URLQueryItem(name: "destination", value: coordinateString),
                    URLQueryItem(name: "travelmode", value: "driving")
                ]
            )

        case .waze:
            return makeURL(
                base: "https://waze.com/ul",
                queryItems: [
                    URLQueryItem(name: "ll", value: coordinateString),
                    URLQueryItem(name: "navigate", value: "yes")
                ]
            )
        }
    }
}

// MARK: - Helpers

private extension MapsLinkBuilder {

    static func makeURL(base: String, queryItems: [URLQueryItem]) -> URL? {
        var components = URLComponents(string: base)
        components?.queryItems = queryItems
        return components?.url
    }

    static func sanitized(_ value: String?) -> String? {
        guard let value else { return nil }

        let trimmed = value
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return trimmed.isEmpty ? nil : trimmed
    }

    static func coordinateText(latitude: Double, longitude: Double) -> String {
        "\(latitude),\(longitude)"
    }
}
