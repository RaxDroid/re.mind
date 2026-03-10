//
//  MapLinkMaker.swift
//  re.mind
//
//  Created by Raul Sanchez on 9/3/26.
//

import Foundation

enum MapsProvider {
    case appleMaps
    case googleMaps
    case waze
}

enum MapsLinkBuilder {

    static func url(for reminder: Reminder, provider: MapsProvider) -> URL? {
        if let geo = reminder.geolocation {
            return url(
                provider: provider,
                latitude: geo.latitude,
                longitude: geo.longitude,
                label: reminder.place ?? geo.resolvedAddress
            )
        }

        if let place = reminder.place, !place.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return url(
                provider: provider,
                placeQuery: place
            )
        }

        return nil
    }

    static func url(provider: MapsProvider, placeQuery: String) -> URL? {
        let query = placeQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }

        switch provider {
        case .appleMaps:
            var components = URLComponents(string: "http://maps.apple.com/")
            components?.queryItems = [
                URLQueryItem(name: "q", value: query)
            ]
            return components?.url

        case .googleMaps:
            var components = URLComponents(string: "https://www.google.com/maps/search/")
            components?.queryItems = [
                URLQueryItem(name: "api", value: "1"),
                URLQueryItem(name: "query", value: query)
            ]
            return components?.url

        case .waze:
            var components = URLComponents(string: "https://waze.com/ul")
            components?.queryItems = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "navigate", value: "yes")
            ]
            return components?.url
        }
    }

    static func url(
        provider: MapsProvider,
        latitude: Double,
        longitude: Double,
        label: String? = nil
    ) -> URL? {
        switch provider {
        case .appleMaps:
            var components = URLComponents(string: "http://maps.apple.com/")
            components?.queryItems = [
                URLQueryItem(name: "ll", value: "\(latitude),\(longitude)"),
                URLQueryItem(name: "q", value: label ?? "\(latitude),\(longitude)")
            ]
            return components?.url

        case .googleMaps:
            var components = URLComponents(string: "https://www.google.com/maps/search/")
            components?.queryItems = [
                URLQueryItem(name: "api", value: "1"),
                URLQueryItem(name: "query", value: "\(latitude),\(longitude)")
            ]
            return components?.url

        case .waze:
            var components = URLComponents(string: "https://waze.com/ul")
            components?.queryItems = [
                URLQueryItem(name: "ll", value: "\(latitude),\(longitude)"),
                URLQueryItem(name: "navigate", value: "yes")
            ]
            return components?.url
        }
    }
}
