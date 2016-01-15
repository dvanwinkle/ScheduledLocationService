//
//  ScheduledLocationService.swift
//  ScheduledLocationService
//
//  Created by Dan VanWinkle on 1/13/16.
//  Copyright © 2016 Dan VanWinkle. All rights reserved.
//

import Foundation
import CoreLocation

public enum ScheduledLocationServiceNotification: String {
    case LocationUpdated = "com.danvw.LocationUpdated"
    case IntervalLocationUpdated = "com.danvw.IntervalLocationUpdated"
    case ImmediateLocationUpdated = "com.danvw.ImmediateLocationUpdated"
    case LocationFailed = "com.danvw.LocationFailed"
}

public class ScheduledLocationService: NSObject, CLLocationManagerDelegate {
    
    // Shared
    public private(set) var gpsPoweredUp = false
    public private(set) var updatingLocation = false
    public var isCurrentlyWantingLocation: Bool {
        return wantingLocationImmediately || wantingLocationOnInterval
    }
    
    // Interval
    public private(set) var updatingOnInterval = false
    public private(set) var wantingLocationOnInterval = false
    public private(set) var updateOnIntervalStartTime: NSDate?
    public var updateInterval: NSTimeInterval = NSTimeInterval.infinity
    public var intervalAccuracyInMeters = kCLLocationAccuracyThreeKilometers
    
    // Immediate
    public private(set) var updatingImmediately = false
    public private(set) var wantingLocationImmediately = false
    public var immediateAccuracyInMeters = kCLLocationAccuracyThreeKilometers
    
    public var locationUpdateTimeout: NSTimeInterval = 5
    public var keepAliveTimerTimeout: NSTimeInterval = 1
    public var keepAliveTime: NSTimeInterval = 300
    
    private let locationManager: CLLocationManager
    private var intervalTimeoutTimer: NSTimer?
    private var intervalStartTimer: NSTimer?
    private var keepAliveTimer: NSTimer?
    private var keepAliveTimeoutTimer: NSTimer?
    private var latestIntervalLocation: CLLocation?
    private var backgroundTask = UIBackgroundTaskInvalid
    private var immediateTimeoutTimer: NSTimer?
    private var latestImmediateLocation: CLLocation?
    
    public override init() {
        locationManager = CLLocationManager()
        locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        locationManager.distanceFilter = CLLocationDistanceMax
        locationManager.activityType = .AutomotiveNavigation
        locationManager.pausesLocationUpdatesAutomatically = false
        
        if #available(iOS 9.0, *) {
            locationManager.allowsBackgroundLocationUpdates = true
        }
        
        super.init()
        
        locationManager.delegate = self
    }
    
    // MARK: - Core Methods
    
    /**
    Starts updating location at the desired interval and accuracy.
    Will post to both the location updated and the interval location updated notifications.
    
    - parameter interval: Interval to update at
    - parameter accuracy: Minimum level of accuracy
    */
    public func startUpdatingLocationWithInterval(interval: NSTimeInterval, andAccuracy accuracy: CLLocationAccuracy) {
        updatingOnInterval = true
        updateInterval = interval
        intervalAccuracyInMeters = accuracy
        
        getIntervalLocation()
    }
    
    /**
     Stops updating location on an interval.
     */
    public func stopUpdatingLocationWithInterval() {
        updatingOnInterval = false
        updateOnIntervalStartTime = nil
        updateInterval = 0
        intervalAccuracyInMeters = kCLLocationAccuracyThreeKilometers
        
        invalidateIntervalTimeoutTimer()
        invalidateIntervalStartTimer()
    }
    
    /**
     Gets a location at the desired accuracy.
     Will post to both the location updated and the interval location updated notifications.
     
     - parameter accuracy: Minimum level of accuracy
     */
    public func getLocationWithAccuracy(accuracy: CLLocationAccuracy) {
        updatingImmediately = true
        immediateAccuracyInMeters = accuracy
        
        getImmediateLocation()
    }
    
    /**
     Starts monitoring for significant location changes.
     */
    public func startMonitoringSignificantLocationChanges() {
        locationManager.startMonitoringSignificantLocationChanges()
    }
    
    /**
     Stops monitoring for significant location changes.
     */
    public func stopMonitoringSignificantLocationChanges() {
        locationManager.stopMonitoringSignificantLocationChanges()
    }
    
    // MARK: - GPS Power
    
    func powerUpGPSWithDesiredAccuracy(desiredAccuracy: CLLocationAccuracy) {
        gpsPoweredUp = true
        
        // Get minimum between current accuracy and desired accuracy in case we are already powered up and need higher accuracy
        locationManager.desiredAccuracy = min(locationManager.desiredAccuracy, desiredAccuracy)
        locationManager.distanceFilter = kCLDistanceFilterNone
    }
    
    func powerDownGPS() {
        gpsPoweredUp = false
        locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        locationManager.distanceFilter = CLLocationDistanceMax
    }
    
    func startUpdatingLocation() {
        if !updatingLocation {
            updatingLocation = true
            
            let authorizationStatus = CLLocationManager.authorizationStatus()
            if authorizationStatus == .Denied || authorizationStatus == .Restricted {
                locationServicesUnavailable()
            } else {
                if authorizationStatus == .NotDetermined {
                    locationManager.requestAlwaysAuthorization()
                }
                
                locationManager.startUpdatingLocation()
            }
        }
    }
    
    // MARK: - Shared
    
    func locationServicesUnavailable() {
        let errorInfo = [NSLocalizedDescriptionKey: "Location services are not enabled."]
        let error = NSError(domain: "com.danvw.scheduledLocationService", code: 100, userInfo: errorInfo)
        
        let userInfo = ["error": error]
        
        NSNotificationCenter.defaultCenter().postNotificationName(ScheduledLocationServiceNotification.LocationFailed.rawValue, object: self, userInfo: userInfo)
    }
    
    // MARK: - Intervals
    
    func getIntervalLocation() {
        wantingLocationOnInterval = true
        updateOnIntervalStartTime = NSDate()
        
        powerUpGPSWithDesiredAccuracy(intervalAccuracyInMeters)
        startUpdatingLocation()
        invalidateIntervalTimeoutTimer()
        
        intervalTimeoutTimer = NSTimer.scheduledTimerWithTimeInterval(locationUpdateTimeout, target: self, selector: "processIntervalLocation", userInfo: nil, repeats: false)
    }
    
    func processIntervalLocation() {
        wantingLocationOnInterval = false
        
        invalidateIntervalTimeoutTimer()
        startIntervalStartTimer()
        
        if !isCurrentlyWantingLocation {
            powerDownGPS()
        }
        
        if let location = latestIntervalLocation {
            let userInfo = ["location": location]
            
            NSNotificationCenter.defaultCenter().postNotificationName(ScheduledLocationServiceNotification.LocationUpdated.rawValue, object: self, userInfo: userInfo)
            NSNotificationCenter.defaultCenter().postNotificationName(ScheduledLocationServiceNotification.IntervalLocationUpdated.rawValue, object: self, userInfo: userInfo)
        }
        
        latestIntervalLocation = nil
    }
    
    func invalidateIntervalTimeoutTimer() {
        if let timer = intervalTimeoutTimer {
            timer.invalidate()
            intervalTimeoutTimer = nil
        }
    }
    
    func invalidateIntervalStartTimer() {
        if let timer = intervalStartTimer {
            timer.invalidate()
            intervalStartTimer = nil
        }
    }
    
    func invalidateKeepAliveTimer() {
        if let timer = keepAliveTimer {
            timer.invalidate()
            keepAliveTimer = nil
        }
    }
    
    func invalidateKeepAliveTimeoutTimer() {
        if let timer = keepAliveTimeoutTimer {
            timer.invalidate()
            keepAliveTimeoutTimer = nil
        }
    }
    
    func keepAlive() {
        invalidateKeepAliveTimer()
        invalidateKeepAliveTimeoutTimer()
        
        powerUpGPSWithDesiredAccuracy(kCLLocationAccuracyBest)
        
        keepAliveTimeoutTimer = NSTimer.scheduledTimerWithTimeInterval(keepAliveTimerTimeout, target: self, selector: "keepAliveTimedOut", userInfo: nil, repeats: false)
    }
    
    func keepAliveTimedOut() {
        invalidateKeepAliveTimer()
        invalidateKeepAliveTimeoutTimer()
        
        powerDownGPS()
        
        if backgroundTask != UIBackgroundTaskInvalid {
            UIApplication.sharedApplication().endBackgroundTask(backgroundTask)
            backgroundTask = UIBackgroundTaskInvalid
        }
        
        startIntervalStartTimer()
    }
    
    func startIntervalStartTimer() {
        invalidateKeepAliveTimer()
        invalidateIntervalStartTimer()
        
        backgroundTask = UIApplication.sharedApplication().beginBackgroundTaskWithExpirationHandler {
            UIApplication.sharedApplication().endBackgroundTask(self.backgroundTask)
            self.backgroundTask = UIBackgroundTaskInvalid
        }
        
        let previousStartTime = updateOnIntervalStartTime ?? NSDate()
        let timeSinceLastStart = NSDate().timeIntervalSinceDate(previousStartTime)
        let timeRemaining = updateInterval - timeSinceLastStart
        
        if timeRemaining < 0 {
            getIntervalLocation()
        } else if timeRemaining > keepAliveTime {
            let timeToTimeout = keepAliveTime - keepAliveTimerTimeout
            
            keepAliveTimer = NSTimer.scheduledTimerWithTimeInterval(timeToTimeout, target: self, selector: "keepAlive", userInfo: nil, repeats: false)
        } else {
            intervalStartTimer = NSTimer.scheduledTimerWithTimeInterval(timeRemaining, target: self, selector: "getIntervalLocation", userInfo: nil, repeats: false)
        }
    }
    
    // MARK: - Immediate
    
    func getImmediateLocation() {
        wantingLocationImmediately = true
        
        powerUpGPSWithDesiredAccuracy(immediateAccuracyInMeters)
        startUpdatingLocation()
        invalidateImmediateTimeoutTimer()
        
        immediateTimeoutTimer = NSTimer(timeInterval: locationUpdateTimeout, target: self, selector: "processImmediateLocation", userInfo: nil, repeats: false)
    }
    
    func processImmediateLocation() {
        wantingLocationImmediately = false
        
        invalidateImmediateTimeoutTimer()
        
        if !isCurrentlyWantingLocation {
            powerDownGPS()
        }
        
        if let latestImmediateLocation = latestImmediateLocation {
            let userInfo = ["location": latestImmediateLocation]
            
            NSNotificationCenter.defaultCenter().postNotificationName(ScheduledLocationServiceNotification.LocationUpdated.rawValue, object: self, userInfo: userInfo)
            NSNotificationCenter.defaultCenter().postNotificationName(ScheduledLocationServiceNotification.ImmediateLocationUpdated.rawValue, object: self, userInfo: userInfo)
        } else {
            NSNotificationCenter.defaultCenter().postNotificationName(ScheduledLocationServiceNotification.LocationFailed.rawValue, object: self, userInfo: ["description": "No location received"])
        }
        
        latestImmediateLocation = nil
    }
    
    func invalidateImmediateTimeoutTimer() {
        if let timer = immediateTimeoutTimer {
            timer.invalidate()
            immediateTimeoutTimer = nil
        }
    }
    
    // MARK: - CLLocationManagerDelegate
    
    @objc public func locationManager(manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if !isCurrentlyWantingLocation {
            return
        }
        
        for location in locations {
            let eventDate = location.timestamp
            let secondsOld = -1 * eventDate.timeIntervalSinceNow
            let validTime = secondsOld <= locationUpdateTimeout
            
            let horizontalAccuracy = location.horizontalAccuracy
            
            if validTime {
                if wantingLocationImmediately {
                    let betterImmediateLocation = latestImmediateLocation != nil && horizontalAccuracy <= latestImmediateLocation!.horizontalAccuracy
                    
                    if latestImmediateLocation == nil || betterImmediateLocation {
                        latestImmediateLocation = location
                        
                        if location.horizontalAccuracy <= immediateAccuracyInMeters {
                            processImmediateLocation()
                        }
                    }
                }
                
                if wantingLocationOnInterval {
                    let betterIntervalLocation = latestIntervalLocation != nil && horizontalAccuracy <= latestIntervalLocation!.horizontalAccuracy
                    
                    if latestIntervalLocation == nil || betterIntervalLocation {
                        latestIntervalLocation = location
                    }
                }
            }
        }
    }
    
    @objc public func locationManager(manager: CLLocationManager, didFailWithError error: NSError) {
        if error.code == CLError.Denied.rawValue {
            let errorInfo = [NSLocalizedDescriptionKey: error.description]
            let errorToPost = NSError(domain: error.domain, code: error.code, userInfo: errorInfo)
            
            let userInfo = ["error": errorToPost]
            
            NSNotificationCenter.defaultCenter().postNotificationName(ScheduledLocationServiceNotification.LocationFailed.rawValue, object: self, userInfo: userInfo)
            
            locationManager.stopUpdatingLocation()
        }
    }
    
    @objc public func locationManager(manager: CLLocationManager, didChangeAuthorizationStatus status: CLAuthorizationStatus) {
        if status == .Denied || status == .Restricted {
            locationServicesUnavailable()
        }
    }
    
}
