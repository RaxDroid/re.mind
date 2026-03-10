//
//  Item.swift
//  re.mind
//
//  Created by Raul Sanchez on 9/3/26.
//

import Foundation
import SwiftData
import MapKit

@Model
final class Reminder {
    var id: UUID = UUID()
    var title: String
    var isCompleted: Bool = false
    var dueDate: Date?
    var notes: String?
    var recurrence: String?
    var place: String?
    var geolocation: GeoLocation?
    var tags: [String] = []
    var calendarIdentifier: String?
    var calendarEventIdentifier: String?
    var calendarItemIdentifier: String?
    var createdOn: Date

    init(
        id: UUID = UUID(),
        title: String,
        isCompleted: Bool = false,
        dueDate: Date? = nil,
        notes: String? = nil,
        recurrence: String? = nil,
        place: String? = nil,
        geolocation: GeoLocation? = nil,
        tags: [String] = [],
        calendarIdentifier: String? = nil,
        calendarEventIdentifier: String? = nil,
        calendarItemIdentifier: String? = nil,
        createdOn: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.isCompleted = isCompleted
        self.dueDate = dueDate
        self.notes = notes
        self.recurrence = recurrence
        self.place = place
        self.geolocation = geolocation
        self.tags = tags
        self.calendarIdentifier = calendarIdentifier
        self.calendarEventIdentifier = calendarEventIdentifier
        self.calendarItemIdentifier = calendarItemIdentifier
        self.createdOn = createdOn
    }
    
    @MainActor
    convenience init(interpretationString: String) {
        let parser = EventParser.shared
        let draft = parser.parse(interpretationString)

        self.init(
            title: draft.title,
            dueDate: draft.dueDate,
            notes: draft.notes,
            recurrence: draft.recurrence,
            place: draft.place,
            geolocation: draft.geolocation,
            tags: draft.tags,
            createdOn: Date()
        )
    }
    
    @MainActor
    func enrichPlace() async throws {
        try await enrichPlace(using: .shared)
    }

    @MainActor
    func enrichPlace(using service: PlaceGeocodingService) async throws {
        guard let place = self.place?.trimmingCharacters(in: .whitespacesAndNewlines),
              !place.isEmpty else {
            return
        }

        let result = try await service.resolve(place: place)
        self.place = result.displayName
        self.geolocation = result.geoLocation
    }

    @MainActor
    func enrichPlace(near region: MKCoordinateRegion) async throws {
        try await enrichPlace(near: region, using: .shared)
    }

    @MainActor
    func enrichPlace(
        near region: MKCoordinateRegion,
        using service: PlaceGeocodingService
    ) async throws {
        guard let place = self.place?.trimmingCharacters(in: .whitespacesAndNewlines),
              !place.isEmpty else {
            return
        }

        let result = try await service.resolve(place: place, near: region)
        self.place = result.displayName
        self.geolocation = result.geoLocation
    }
    
    func mapURL(for provider: MapsProvider) -> URL? {
        MapsLinkBuilder.url(for: self, provider: provider)
    }

    func navigationURL(for provider: MapsProvider) -> URL? {
        MapsLinkBuilder.directionsURL(for: self, provider: provider)
    }

    var appleMapsURL: URL? {
        mapURL(for: .appleMaps)
    }

    var googleMapsURL: URL? {
        mapURL(for: .googleMaps)
    }

    var wazeURL: URL? {
        mapURL(for: .waze)
    }

    var preferredMapURL: URL? {
        googleMapsURL ?? appleMapsURL ?? wazeURL
    }

    var appleMapsNavigationURL: URL? {
        navigationURL(for: .appleMaps)
    }

    var googleMapsNavigationURL: URL? {
        navigationURL(for: .googleMaps)
    }

    var wazeNavigationURL: URL? {
        navigationURL(for: .waze)
    }
}

@Model
final class GeoLocation: Equatable {
    var latitude: Double
    var longitude: Double
    var resolvedAddress: String?

    init(latitude: Double, longitude: Double, resolvedAddress: String? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.resolvedAddress = resolvedAddress
    }

    static func == (lhs: GeoLocation, rhs: GeoLocation) -> Bool {
        lhs.latitude == rhs.latitude &&
        lhs.longitude == rhs.longitude &&
        lhs.resolvedAddress == rhs.resolvedAddress
    }
}
