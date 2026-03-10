//
//  Extensions.swift
//  re.mind
//
//  Created by Raul Sanchez on 10/3/26.
//

import Foundation
import UIKit

enum MapsLauncher {

    static func open(_ url: URL) {
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}
