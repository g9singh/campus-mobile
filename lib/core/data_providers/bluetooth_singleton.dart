import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:math';
import 'package:background_fetch/background_fetch.dart';
import 'package:campus_mobile_experimental/core/services/networking.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue/flutter_blue.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:location/location.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:campus_mobile_experimental/core/data_providers/user_data_provider.dart';

import 'bluetooth_broadcast_singleton.dart';

class BluetoothSingleton {
  // Booleans for instantiating permissions
  bool firstInstance = true;
  bool dataOffloadAuthorized = false;

  SharedPreferences prefs;


  // Hashmap to track time stamps
  HashMap<String, BluetoothDeviceProfile> scannedObjects = new HashMap();

  // Internal Declaration
  static final BluetoothSingleton _bluetoothSingleton =
      BluetoothSingleton._internal();

  //Flutter blue instance for scanning
  FlutterBlue flutterBlueInstance = FlutterBlue.instance;

  // Will add at the end, slows down scans
  final _storage = FlutterSecureStorage();

  /// Initialize header
  final Map<String, String> header = {'Authorization': 'Bearer '};

  final Map<String, String> constantsHeader = {'Authorization': ' Bearer '};

  // Advertisement string
  String advertisementValue;
  // Holders for location
  final NetworkHelper _networkHelper = NetworkHelper();
  String bluetoothConstantsEndpoint =
      "https://api-qa.ucsd.edu:8243/bluetoothscanningcharacteristics/v1.0/constants";
  String bluetoothCharacteristicsEndpoint =
      "https://api-qa.ucsd.edu:8243/bluetoothdevicecharacteristic/v1.0.0/servicenames/1";
String offloadLoggerEndpoint  = "https://api-qa.ucsd.edu:8243/mobileapplogger/v1.0.0";

  //Thresholds for logging location
  int uniqueIdThreshold = 0;
  int distanceThreshold = 10; // default in ZenHub

  // Keep track of devices that meet our requirements
  int uniqueDevices = 0;

  // Dwell time threshold (10 minutes -> 600 seconds;
  int dwellTimeThreshold = 200;

  // Constant for scans
  int scanDuration = 2; //Seconds
  int waitTime = 15; // Seconds

  // Tracker to enable location listener
  int enable = 0;

  // Allows for continuous scan
  Timer ongoingScanner;

  // Lists for displaying scan results
  List loggedItems = [];
  static List<List<String>> bufferList = [];
  static List<ScanResult> scannedDevices = [];

  //initialize location and permissions to be checked
  Location location = Location();
  LocationData _currentLocation;
  /// Initialize header
   Map<String, String> offloadDataHeader;

  // Device Types
  Map<String, dynamic> deviceTypes;
UserDataProvider userDataProvider;
  //flutterBlueInstance.scan(timeout: Duration(seconds: scanDuration), allowDuplicates: false)
  factory BluetoothSingleton() {
    // bluetoothStream();
    return _bluetoothSingleton;
  }

  // Initial method for scan set up
  init() async {
   offloadDataHeader = {
    'Authorization':
    'Bearer ${userDataProvider?.authenticationModel?.accessToken}'
    };
    await SharedPreferences.getInstance().then((value) {
    prefs = value;
    if(prefs.containsKey("offloadPermission")){
      dataOffloadAuthorized = prefs.getBool("offloadPermission");
    }else{
      prefs.setBool("offloadPermission", dataOffloadAuthorized);
    }
  });


    // Only start scanning when permissions granted
    await flutterBlueInstance.isAvailable.then((value) {
      flutterBlueInstance.state.listen((event) async {

        // If BT is on
        if (event.index == 4) {
          BeaconSingleton beaconBroadcast = BeaconSingleton();
          beaconBroadcast.init();
          advertisementValue = beaconBroadcast.advertisingUUID;
          backgroundFetchSetUp();
          firstInstance = false;

          await getData();

          // Set the minimum change to activate a new scan.
          location.changeSettings(accuracy: LocationAccuracy.low);

          // Enable location listening
          _logLocation();

          // Enable continuous scan
          enableScanning();
        }
      });
    });
  }

  // Set background tasks
  void backgroundFetchSetUp() {

    // Configure BackgroundFetch.
    BackgroundFetch.configure(
            BackgroundFetchConfig(
              minimumFetchInterval: 15,
              forceAlarmManager: false,
              stopOnTerminate: false,
              startOnBoot: true,
              enableHeadless: true,
              requiresBatteryNotLow: false,
              requiresCharging: false,
              requiresStorageNotLow: false,
              requiresDeviceIdle: false,
              requiredNetworkType: NetworkType.NONE,
            ),
            _onBackgroundFetch)
        .then((int status) {
      _storage.write(
          key: _randomValue(),
          value: '[BackgroundFetch] configure success: $status');
    }).catchError((e) {
      _storage.write(
          key: _randomValue(), value: '[BackgroundFetch] configure ERROR: $e');
    });
  }

  /// This function starts continuous scan (on home screen)
  enableScanning() {
    //Start the initial scan
    Timer.run(() {
      startScan();
    });
    // Enable timer, must wait duration before next method execution
    ongoingScanner = new Timer.periodic(
        Duration(seconds: waitTime), (Timer t) => startScan());
  }

  //Get constants for scanning
  Future<void> getData() async {
    String _response = await _networkHelper.authorizedFetch(
        bluetoothConstantsEndpoint, constantsHeader);
    final _json = json.decode(_response);
    uniqueIdThreshold = int.parse(_json["uniqueDevices"]);
    distanceThreshold = int.parse(_json["distanceThreshold"]);
    dwellTimeThreshold = int.parse(_json["dwellTimeThreshold"]);
    scanDuration = int.parse(_json["scanDuration"]);
    waitTime = int.parse(_json["waitTime"]) * 10;
  }



  // Start a bluetooth scan of 2 second duration and listen to results
  startScan() {
    flutterBlueInstance.startScan(
        timeout: Duration(seconds: 2), allowDuplicates: false);

    // Process the scan results (synchronously)
    flutterBlueInstance.scanResults.listen((results) {
      for (ScanResult scanResult in results) {
        String calculatedUUID;

        scanResult.advertisementData.manufacturerData
            .forEach((item, hexcodeAsArray) => {
                  calculatedUUID = ("calculated UUID String : " +
                      calculateHexFromArray(hexcodeAsArray))
                });

        //Create BT Objects to render + check continuity
        identifyDevices(scanResult);

        bool repeatedDevice = checkForDuplicates(scanResult);

        //PARSE FOR FRONTEND DISPLAY
        frontEndFilter(repeatedDevice, scanResult, calculatedUUID);
      }
    });

    // Remove objects that are no longer continuous found
    removeNoncontinuousDevices();


    // Include device type for threshold
    List<Map> newBufferList = identifyDeviceTypes();

    // Add the processed buffer to overall log
    //loggedItems.insertAll(loggedItems.length, newBufferList);

    bool logLocation = false;
    double lat;
    double long;
    // If there are more than three devices, log location
    if (uniqueDevices >= uniqueIdThreshold) {
      //loggedItems.add("LOCATION LOGGED");
       _logLocation();
        logLocation = true;
       location.getLocation().then((value) {
         lat = value.latitude;

       });
       location.getLocation().then((value) {
         long = value.longitude;
       });

       // Reset dwell times
      resetDevices();
      uniqueDevices = 0;
    }

    //LOG VALUE
    Map log = {"AdvertisementID": this.advertisementValue, "Source": "CampusMobileApp", "Latitude": lat.toString(), "Longitude": long.toString(), "Timestamp":DateTime.fromMillisecondsSinceEpoch(
        DateTime.now().millisecondsSinceEpoch)
        .toString(), "btList" : newBufferList};
      _networkHelper.authorizedPost(offloadLoggerEndpoint, offloadDataHeader, log).then((value) {
        print(value.toString());
      });

      print("Device log" + log.toString());
    // Store timestamp
   // _storage.write(key: _randomValue(), value: timeStamp);

    // Close on going scan in case it has not time out
    flutterBlueInstance.stopScan();

    // Clear previous scan results
    bufferList.clear();
    newBufferList.clear();

  }
// Identify types of device, currently working for Apple devices
  List<Map> identifyDeviceTypes() {
    List<Map> formattedLists = [];
    List<List<String>> newBufferList = [];
    for (List<String> deviceEntry in bufferList) {
      if (Platform.isIOS) {
        deviceEntry.insert(1,
            ((scannedObjects[deviceEntry[0].substring(4, 40)].deviceType != "")
                ? "Device type: ${getAppleClassification(
                scannedObjects[deviceEntry[0].substring(4, 40)].deviceType)}"
                : "Unavailable"));
      } else if (Platform.isAndroid) {
        deviceEntry.insert(1,
            ((scannedObjects[deviceEntry[0].substring(4, 21)].deviceType != "")
                ? "${getAppleClassification(
                scannedObjects[deviceEntry[0].substring(4, 21)].deviceType)}"
                : "Unavailable"));
      }
      newBufferList.add(deviceEntry);
    }

    for (List<String> deviceEntry in newBufferList) {
      Map<String, String> deviceLog = {
        "DeviceID": deviceEntry[0],
        "Type": deviceEntry[1],
        "UCSDAPP": deviceEntry[3],
        "DetectStart": deviceEntry[4],
        "DetectCurrent": TimeOfDay.now().toString(),
        "DetectSignalStrength": deviceEntry[5],
        "DetectDistance": deviceEntry[6]
      };
      formattedLists.add(deviceLog);
    }
    return formattedLists;

  }

  // Reset device dwell time when used to track user's location
  void resetDevices() {
    scannedObjects.forEach((key, value) {
      if (value.timeThresholdMet) {
        value.timeThresholdMet = false;
        value.dwellTime = 0;
      }
    });
  }

  //Gather information on device scanned
  void identifyDevices(ScanResult scanResult) {
    scannedObjects.update(scanResult.device.id.toString(), (value) {
      value.continuousDuration = true;
      value.rssi = scanResult.rssi;
      if (scanResult.advertisementData.txPowerLevel != null) {
        value.txPowerLevel = scanResult.advertisementData.txPowerLevel;
      }
      return value;
    },
        ifAbsent: () => new BluetoothDeviceProfile(
            scanResult.device.id.toString(),
            scanResult.rssi,
            "",
            new List<TimeOfDay>.from({TimeOfDay.now()}),
            true,
            scanResult.advertisementData.txPowerLevel));
  }

  // Ensure we only process unique devices during one scan
  bool checkForDuplicates(ScanResult scanResult) {
    bool repeatedDevice = false;
    bufferList.forEach((element) {
      String toFind = 'ID: ${scanResult.device.id}';
      if (element.contains(toFind)) {
        repeatedDevice = true;
      }
    });
    return repeatedDevice;
  }

  // Identify the Apple device type
  String getAppleClassification(String manufacturerName) {
    String deviceType = "";
    if (manufacturerName.contains("Mac")) {
      deviceType = "Computer";
    } else if (manufacturerName.contains("iPhone")) {
      deviceType = "Phone";
    } else if (manufacturerName.contains("Audio")) {
      deviceType = "Audio Output";
    } else if (manufacturerName.contains("iPad")) {
      deviceType = "Tablet";
    } else if (manufacturerName.contains("Watch")) {
      deviceType = "Watch";
    }
    return deviceType;
  }

  //Remove devices that are no longer scanned
  void removeNoncontinuousDevices() {
    List<String> objectsToRemove = [];
    scannedObjects.forEach((key, value) {
      if (!value.continuousDuration) {
        objectsToRemove.add(key);
      }
    });
    objectsToRemove.forEach((element) {
      scannedObjects.remove(element);
    });
  }

  // Determine if we use the type to log location
  bool eligibleType(String manufacturerName) {
    return getAppleClassification(manufacturerName) != "" ? true : false;
  }

  // Originally for on screen rendering but also calculates devices that meet our requirements
  void frontEndFilter(
      bool repeatedDevice, ScanResult scanResult, String calculatedUUID) {
    if (!repeatedDevice) {
      scannedObjects[scanResult.device.id.toString()].dwellTime += (waitTime);
      scannedObjects[scanResult.device.id.toString()].distance =
          getDistance(scanResult.rssi);
      if (scannedObjects[scanResult.device.id.toString()].dwellTime >=
              dwellTimeThreshold &&
          scannedObjects[scanResult.device.id.toString()].distance <=
              distanceThreshold &&
          eligibleType(
              scannedObjects[scanResult.device.id.toString()].deviceType)) {
        uniqueDevices += 1; // Add the # of unique devices detected
      }

      // Log important information
      String deviceLog = 'ID: ${scanResult.device.id}';

      bool isUCSDapp = false;
      if(calculatedUUID != null){
        isUCSDapp = calculatedUUID.contains(this.advertisementValue.replaceAll("-", ""));

      }
      List<String> actualDeviceLog = [deviceLog, scanResult.device.id.toString(),isUCSDapp.toString(), scannedObjects[scanResult.device.id.toString()].timeStamps[0].toString(), scanResult.rssi.toString(), scannedObjects[scanResult.device.id.toString()].distance.toString() ];

      bufferList.add(actualDeviceLog);
     // _storage.write(key: _randomValue(), value: deviceLog);
      // Optimize device connection
      if (scanResult.advertisementData.connectable &&
          scannedObjects[scanResult.device.id.toString()].deviceType == "" &&
          scanResult != null) {
        extractBTServices(scanResult);
      }
    }
  }

  // Extract services from connect device to identify type
  void extractBTServices(ScanResult scanResult) async {
    try {
      scanResult.device.connect().then((value) {
        scanResult.device.discoverServices().then((value) {
          value.forEach((element) {
            if (element.uuid.toString().toUpperCase().contains("180A")) {
              element.characteristics.forEach((element) {
                if (element.toString().toUpperCase().contains("2A24")) {
                  element.read().then((value) {
                    scannedObjects[scanResult.device.id.toString()].deviceType =
                        "${ascii.decode(value).toString()}";
                  });
                }
              });
            }
          });
        });
      });
    } catch (exception) {}
  }


  // Used to log current user location or enable the location change listener
  void _logLocation() async {
    // Set up new location object to get current location
    location = Location();
    location.changeSettings(accuracy: LocationAccuracy.low);
    PermissionStatus hasPermission;
    bool _serviceEnabled;

    // check if gps service is enabled
    _serviceEnabled = await location.serviceEnabled();
    if (!_serviceEnabled) {
      _serviceEnabled = await location.requestService();
      if (!_serviceEnabled) {
        return;
      }
    }
    //check if permission is granted
    hasPermission = await location.hasPermission();
    if (hasPermission == PermissionStatus.denied) {
      hasPermission = await location.requestPermission();
      if (hasPermission != PermissionStatus.granted) {
        return;
      }
    }

    //once permissions are verified, get location asynchronously
    _currentLocation = await location.getLocation();

    // Location Logging
    String logLocation = " LATITUDE: " +
        _currentLocation.latitude.toString() +
        " LONGITUDE: " +
        _currentLocation.longitude.toString() +
        "\n";

    // Add location logging to rendered list
    //loggedItems.add(logLocation);

    // Store location logs
    _storage.write(key: _randomValue(), value: logLocation);
  }

  // Get the rough distance from bt device
  double getDistance(int rssi) {
    var txPower = -59; //hardcoded for now
    var ratio = (rssi * 1.0) / txPower;
    if (ratio < 1.0) {
      return (math.pow(ratio, 10) *
          3.28084); //multiply by 3.. for meters to feet conversion
    } else {
      return ((0.89976 * math.pow(ratio, 7.7095) + 0.111) *
          3.28084); //https://haddadi.github.io/papers/UBICOMP2016iBeacon.pdf
    }
  }

  // Internal constructor
  BluetoothSingleton._internal();

  // Log storage size
  /*Future<Null> _readAll() async {
    final all = await _storage.readAll();
  }*/


  // Key generator for storage
  String _randomValue() {
    final rand = Random();
    final codeUnits = List.generate(20, (index) {
      return rand.nextInt(26) + 65;
    });

    return String.fromCharCodes(codeUnits);
  }

  // Alert dialog for offloading data
  void getOffloadAuthorization(BuildContext context) {
    showDialog(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext context) {
          if (Platform.isIOS) {
            return CupertinoAlertDialog(
              title:
                  Text("Allow UC San Diego Mobile to offload bluetooth logs?"),
              content: Text(
                  "Bluetooth logs will be offloaded to ensure optimal performance."),
              actions: <Widget>[
                CupertinoDialogAction(
                  child: Text('Don\'t Allow'),
                  onPressed: () {
                    Navigator.of(context).pop();
                  },
                ),
                CupertinoDialogAction(
                  child: Text('Allow'),
                  onPressed: () {
                    this.dataOffloadAuthorized = true;
                    Navigator.of(context).pop();
                  },
                )
              ],
            );
          }
          return AlertDialog(
            title: Text("Allow UC San Diego Mobile to offload bluetooth logs?"),
            content: Text(
                "Bluetooth logs will be offloaded to ensure optimal performance."),
            actions: <Widget>[
              FlatButton(
                child: Text('Don\'t Allow'),
                onPressed: () {
                  Navigator.of(context).pop();
                },
              ),
              FlatButton(
                child: Text('Allow'),
                onPressed: () {
                  this.dataOffloadAuthorized = true;
                  Navigator.of(context).pop();
                },
              )
            ],
          );
        });
  }
  // Start a background scan
  void _onBackgroundFetch(String taskID) async {
    startScan();
    BackgroundFetch.finish(taskID);
  }
  //Parse advertisement data
  String calculateHexFromArray(decimalArray) {
    String uuid = '';
    decimalArray.forEach((i) => {uuid += i.toRadixString(16).padLeft(2, '0')});
    try {
      String uuid1 = uuid.substring(4, uuid.length - 12);
      return uuid1.toUpperCase();
    } catch (Exception) {
      return uuid;
    }
  }
}

// Helper Class
class BluetoothDeviceProfile {
  String uuid;
  int rssi;
  String deviceType;
  List<TimeOfDay> timeStamps;
  bool continuousDuration;
  int measuredPower;
  double distance; // Feet
  int txPowerLevel;
  double dwellTime = 0;
  bool timeThresholdMet = false;

  BluetoothDeviceProfile(this.uuid, this.rssi, this.deviceType, this.timeStamps,
      this.continuousDuration, this.measuredPower);
}
