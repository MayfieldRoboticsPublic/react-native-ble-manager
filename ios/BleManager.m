#import "BleManager.h"
#import "RCTBridge.h"
#import "RCTConvert.h"
#import "RCTEventDispatcher.h"
#import "NSData+Conversion.h"
#import "CBPeripheral+Extensions.h"
#import "BLECommandContext.h"

const int MTU = 20;

@implementation BleManager

RCT_EXPORT_MODULE();

- (instancetype)init {

    if (self = [super init]) {
        NSLog(@"BleManager initialized");
        _peripherals = [NSMutableSet set];
        _manager = [[CBCentralManager alloc] initWithDelegate:self queue:dispatch_get_main_queue()];

        connectCallbacks = [NSMutableDictionary new];
        connectCallbackLatches = [NSMutableDictionary new];
        readCallbacks = [NSMutableDictionary new];
        writeCallbacks = [NSMutableDictionary new];
        writeQueue = [NSMutableArray array];
        notificationCallbacks = [NSMutableDictionary new];
        stopNotificationCallbacks = [NSMutableDictionary new];
        isObserved = false;
    }

    return self;
}

#pragma mark - RCTEventEmitter

- (NSArray<NSString *> *)supportedEvents {
    return @[
             @"BleManagerDidUpdateValueForCharacteristic",
             @"BleManagerDidStopScan",
             @"BleManagerDidDiscoverPeripheral",
             @"BleManagerDidUpdateState",
             @"BleManagerDidDisconnectPeripheral",
             ];
}

- (void)startObserving {
    isObserved = true;
}

- (void)stopObserving {
    isObserved = false;
}

# pragma mark - CBPeripheralDelegate

- (void)peripheral:(CBPeripheral *)peripheral didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (error) {
        NSLog(@"Error (characteristic %@): %@", characteristic.UUID, error);
        return;
    }

    NSLog(@"Read value (characteristic %@): %@", characteristic.UUID, characteristic.value);

    NSString *key = [self keyForPeripheral:peripheral andCharacteristic:characteristic];
    RCTPromiseResolveBlock readCallback = [readCallbacks objectForKey:key];

    NSString *stringFromData = [characteristic.value hexadecimalString];

    if (readCallback != NULL){
        readCallback(@[stringFromData]);
        [readCallbacks removeObjectForKey:key];
    } else {
        [self sendEventWithName:@"BleManagerDidUpdateValueForCharacteristic"
                           body:@{
                                  @"peripheral": peripheral.uuidAsString,
                                  @"characteristic": characteristic.UUID.UUIDString,
                                  @"value": stringFromData
                                  }];
    }
}

- (void)peripheral:(CBPeripheral *)peripheral didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (error) {
        NSLog(@"Error in didUpdateNotificationStateForCharacteristic: %@", error);
        return;
    }

    // Call didUpdateValueForCharacteristic only when we have a value.
    /*
     if (characteristic.value)
     {
     NSLog(@"Received value from notification: %@", characteristic.value);
     }*/

    NSString *key = [self keyForPeripheral:peripheral andCharacteristic:characteristic];

    if (characteristic.isNotifying) {
        NSLog(@"Notification began on %@", characteristic.UUID);
        RCTPromiseResolveBlock notificationCallback = [notificationCallbacks objectForKey:key];
        notificationCallback(@{});
        [notificationCallbacks removeObjectForKey:key];
    } else {
        // Notification has stopped
        NSLog(@"Notification ended on %@", characteristic.UUID);
        RCTPromiseResolveBlock stopNotificationCallback = [stopNotificationCallbacks objectForKey:key];
        stopNotificationCallback(@{});
        [stopNotificationCallbacks removeObjectForKey:key];
    }
}

- (void)peripheral:(CBPeripheral *)peripheral didWriteValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    NSString *key = [self keyForPeripheral: peripheral andCharacteristic:characteristic];
    RCTPromiseResolveBlock writeCallback = [writeCallbacks objectForKey:key];

    if (writeCallback) {
        if (error) {
            NSLog(@"Error %@", error);
        } else {
            if ([writeQueue count] == 0) {
                writeCallback(@"");
                [writeCallbacks removeObjectForKey:key];
            } else {
                // Remove message from queue
                NSData *message = [writeQueue objectAtIndex:0];
                [writeQueue removeObjectAtIndex:0];
                NSLog(@"Remaining in queue: %i", [writeQueue count]);
                NSLog(@"Writing message (%lu): %@ ", (unsigned long)[message length], [message hexadecimalString]);
                [peripheral writeValue:message forCharacteristic:characteristic type:CBCharacteristicWriteWithResponse];
            }
        }
    }
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    if (error) {
        NSLog(@"Error: %@", error);
        return;
    }

    NSMutableSet *servicesForPeriperal = [NSMutableSet new];
    [servicesForPeriperal addObjectsFromArray:peripheral.services];
    [connectCallbackLatches setObject:servicesForPeriperal forKey:peripheral.uuidAsString];

    for (CBService *service in peripheral.services) {
        NSLog(@"Discovered service %@ %@", service.UUID, service.description);
        [peripheral discoverCharacteristics:nil forService:service]; // discover all is slow
    }
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error {
    if (error) {
        NSLog(@"Error: %@", error);
        return;
    }

    NSString *peripheralUUIDString = [peripheral uuidAsString];
    RCTPromiseResolveBlock connectCallback = [connectCallbacks valueForKey:peripheralUUIDString];
    NSMutableSet *latch = [connectCallbackLatches valueForKey:peripheralUUIDString];
    [latch removeObject:service];

    if ([latch count] == 0) {
        // Call success callback for connect
        if (connectCallback) {
            connectCallback([peripheral asDictionary]);
        }
        [connectCallbackLatches removeObjectForKey:peripheralUUIDString];
    }
}

# pragma mark - CBCentralManagerDelegate

- (void)centralManager:(CBCentralManager *)central
 didDiscoverPeripheral:(CBPeripheral *)peripheral
     advertisementData:(NSDictionary *)advertisementData
                  RSSI:(NSNumber *)RSSI {
    [self.peripherals addObject:peripheral];
    [peripheral setAdvertisementData:advertisementData RSSI:RSSI];

    NSLog(@"Discovered peripheral: %@", [peripheral asDictionary]);
    [self sendEventWithName:@"BleManagerDidDiscoverPeripheral" body:[peripheral asDictionary]];

}

- (void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    NSLog(@"Failed to connect to peripheral: %@. (%@)", [peripheral asDictionary], [error localizedDescription]);
}

- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
    NSLog(@"Peripheral connected: %@", peripheral.uuidAsString);

    peripheral.delegate = self;
    [peripheral discoverServices:nil];
}

- (void)centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    NSLog(@"Peripheral disconnected: %@", peripheral.uuidAsString);

    if (error) {
        NSLog(@"Error: %@", error);
    }

    [self sendEventWithName:@"BleManagerDidDisconnectPeripheral" body:@{
                                                                        @"peripheral": peripheral.uuidAsString
                                                                        }];
}

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    if (!isObserved) {
        return;
    }

    NSString *stateName = [self centralManagerStateToString:central.state];
    [self sendEventWithName:@"BleManagerDidUpdateState" body:@{ @"state": stateName }];
}

# pragma mark - Private

- (NSString *)centralManagerStateToString:(int)state {
    switch (state) {
        case CBCentralManagerStateUnknown:
            return @"unknown";
        case CBCentralManagerStateResetting:
            return @"resetting";
        case CBCentralManagerStateUnsupported:
            return @"unsupported";
        case CBCentralManagerStateUnauthorized:
            return @"unauthorized";
        case CBCentralManagerStatePoweredOff:
            return @"off";
        case CBCentralManagerStatePoweredOn:
            return @"on";
        default:
            return @"unknown";
    }

    return @"unknown";
}

- (NSString *)peripheralStateToString:(int)state {
    switch (state) {
        case CBPeripheralStateDisconnected:
            return @"disconnected";
        case CBPeripheralStateDisconnecting:
            return @"disconnecting";
        case CBPeripheralStateConnected:
            return @"connected";
        case CBPeripheralStateConnecting:
            return @"connecting";
        default:
            return @"unknown";
    }

    return @"unknown";
}

- (NSString *)peripheralManagerStateToString:(int)state {
    switch (state) {
        case CBPeripheralManagerStateUnknown:
            return @"Unknown";
        case CBPeripheralManagerStatePoweredOn:
            return @"PoweredOn";
        case CBPeripheralManagerStatePoweredOff:
            return @"PoweredOff";
        default:
            return @"unknown";
    }

    return @"unknown";
}

- (CBPeripheral *)findPeripheralByUUID:(NSString *)uuid {
    CBPeripheral *peripheral = nil;

    for (CBPeripheral *p in self.peripherals) {
        if ([uuid isEqualToString:p.identifier.UUIDString]) {
            peripheral = p;
            break;
        }
    }

    return peripheral;
}

- (CBService *)findServiceFromUUID:(CBUUID *)UUID p:(CBPeripheral *)p {
    for (int i = 0; i < p.services.count; i++) {
        CBService *s = [p.services objectAtIndex:i];
        if ([self compareCBUUID:s.UUID UUID2:UUID]) {
            return s;
        }
    }

    return nil; //Service not found on this peripheral
}

- (int)compareCBUUID:(CBUUID *)UUID1 UUID2:(CBUUID *)UUID2 {
    char b1[16];
    char b2[16];
    [UUID1.data getBytes:b1 length:16];
    [UUID2.data getBytes:b2 length:16];

    if (memcmp(b1, b2, UUID1.data.length) == 0) {
        return 1;
    }

    return 0;
}


RCT_EXPORT_METHOD(scan:(NSArray *)serviceUUIDStrings
                  timeoutSeconds:(nonnull NSNumber *)timeoutSeconds
                  allowDuplicates:(BOOL)allowDuplicates
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    NSLog(@"Starting scan with timeout %@", timeoutSeconds);

    NSArray *services = [RCTConvert NSArray:serviceUUIDStrings];
    NSMutableArray *serviceUUIDs = [NSMutableArray new];
    NSDictionary *options = nil;

    if (allowDuplicates){
        options = [NSDictionary dictionaryWithObject:[NSNumber numberWithBool:YES] forKey:CBCentralManagerScanOptionAllowDuplicatesKey];
    }

    for (int i = 0; i < [services count]; i++) {
        CBUUID *serviceUUID = [CBUUID UUIDWithString:[serviceUUIDStrings objectAtIndex:i]];
        [serviceUUIDs addObject:serviceUUID];
    }
    [self.manager scanForPeripheralsWithServices:serviceUUIDs options:options];

    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:[timeoutSeconds floatValue] target:self selector:@selector(stopScanTimer:) userInfo:nil repeats:NO];
    });
    resolve(@{});
}

-(void)stopScanTimer:(NSTimer *)timer {
    NSLog(@"Stop scan");
    [self.manager stopScan];
    [self sendEventWithName:@"BleManagerDidStopScan" body:@{}];
}

RCT_EXPORT_METHOD(connect:(NSString *)peripheralUUID
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    CBPeripheral *peripheral = [self findPeripheralByUUID:peripheralUUID];

    if (peripheral) {
        NSLog(@"Connecting to peripheral with UUID: %@", peripheralUUID);

        [connectCallbacks setObject:resolve forKey:peripheral.uuidAsString];
        [self.manager connectPeripheral:peripheral options:nil];
    } else {
        NSString *error = [NSString stringWithFormat:@"Could not find peripheral %@.", peripheralUUID];
        NSLog(@"Error: %@", error);
        reject(@"BLE_PERIPHERAL_NOT_FOUND", error, nil);
    }
}

RCT_EXPORT_METHOD(disconnect:(NSString *)peripheralUUID
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    CBPeripheral *peripheral = [self findPeripheralByUUID:peripheralUUID];

    if (peripheral) {
        NSLog(@"Disconnecting from peripheral with UUID: %@", peripheralUUID);

        if (peripheral.services != nil) {
            for (CBService *service in peripheral.services) {
                if (service.characteristics != nil) {
                    for (CBCharacteristic *characteristic in service.characteristics) {
                        if (characteristic.isNotifying) {
                            NSLog(@"Removing notification from: %@", characteristic.UUID);
                            [peripheral setNotifyValue:NO forCharacteristic:characteristic];
                        }
                    }
                }
            }
        }

        [self.manager cancelPeripheralConnection:peripheral];
        resolve(@{});
    } else {
        NSString *error = [NSString stringWithFormat:@"Could not find peripheral %@.", peripheralUUID];
        NSLog(@"Error: %@", error);
        reject(@"BLE_PERIPHERAL_NOT_FOUND", error, nil);
    }
}

RCT_EXPORT_METHOD(checkState) {
    if (self.manager != nil) {
        [self centralManagerDidUpdateState:self.manager];
    }
}

RCT_EXPORT_METHOD(write:(NSString *)deviceUUID
                  serviceUUID:(NSString *)serviceUUID
                  characteristicUUID:(NSString *)characteristicUUID
                  message:(NSString *)message
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    BLECommandContext *context = [self getData:deviceUUID
                             serviceUUIDString:serviceUUID
                      characteristicUUIDString:characteristicUUID
                                          prop:CBCharacteristicPropertyWrite
                                  failCallback:reject];

    NSData *dataMessage = [[NSData alloc] initWithBase64EncodedString:message options:0];
    if (context) {
        CBPeripheral *peripheral = [context peripheral];
        CBCharacteristic *characteristic = [context characteristic];

        NSString *key = [self keyForPeripheral:peripheral andCharacteristic:characteristic];
        [writeCallbacks setObject:resolve forKey:key];

        RCTLogInfo(@"Message to write (%lu): %@ ", (unsigned long)dataMessage.length, [dataMessage hexadecimalString]);

        if (dataMessage.length > MTU){
            int dataLength = (int)dataMessage.length;
            int count = 0;
            NSData *firstMessage;
            while (count < dataLength && (dataLength - count > MTU)){
                if (count == 0){
                    firstMessage = [dataMessage subdataWithRange:NSMakeRange(count, MTU)];
                } else {
                    NSData *splitMessage = [dataMessage subdataWithRange:NSMakeRange(count, MTU)];
                    [writeQueue addObject:splitMessage];
                }
                count += MTU;
            }

            if (count < dataLength) {
                NSData *splitMessage = [dataMessage subdataWithRange:NSMakeRange(count, dataLength - count)];
                [writeQueue addObject:splitMessage];
            }

            NSLog(@"Queued chunked message: %lu", (unsigned long)[writeQueue count]);
            [peripheral writeValue:firstMessage forCharacteristic:characteristic type:CBCharacteristicWriteWithResponse];
        } else {
            [peripheral writeValue:dataMessage forCharacteristic:characteristic type:CBCharacteristicWriteWithResponse];
        }
    } else {
        reject(@"BLE_CONTEXT_NOT_INITIALIZED", @"Could not initialize BLE command context", nil);
    }
}

RCT_EXPORT_METHOD(writeWithoutResponse:(NSString *)deviceUUID
                  serviceUUID:(NSString *)serviceUUID
                  characteristicUUID:(NSString *)characteristicUUID
                  message:(NSString *)message
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    BLECommandContext *context = [self getData:deviceUUID
                             serviceUUIDString:serviceUUID
                      characteristicUUIDString:characteristicUUID
                                          prop:CBCharacteristicPropertyWriteWithoutResponse
                                  failCallback:reject];

    NSData *dataMessage = [[NSData alloc] initWithBase64EncodedString:message options:0];
    if (context) {
        CBPeripheral *peripheral = context.peripheral;
        CBCharacteristic *characteristic = context.characteristic;

        NSLog(@"Message to write without response (%lu): %@ ", (unsigned long)dataMessage.length, [dataMessage hexadecimalString]);

        // TODO need to check the max length
        [peripheral writeValue:dataMessage forCharacteristic:characteristic type:CBCharacteristicWriteWithoutResponse];
        resolve(@{});
    } else {
        reject(@"BLE_CONTEXT_NOT_INITIALIZED", @"Could not initialize BLE command context", nil);
    }
}

RCT_EXPORT_METHOD(read:(NSString *)deviceUUID
                  serviceUUID:(NSString *)serviceUUID
                  characteristicUUID:(NSString *)characteristicUUID
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    BLECommandContext *context = [self getData:deviceUUID
                             serviceUUIDString:serviceUUID
                      characteristicUUIDString:characteristicUUID
                                          prop:CBCharacteristicPropertyRead
                                  failCallback:reject];
    if (context) {
        CBPeripheral *peripheral = context.peripheral;
        CBCharacteristic *characteristic = context.characteristic;

        NSString *key = [self keyForPeripheral:peripheral andCharacteristic:characteristic];
        [readCallbacks setObject:resolve forKey:key];

        [peripheral readValueForCharacteristic:characteristic]; // callback sends value
    }
}

RCT_EXPORT_METHOD(startNotification:(NSString *)deviceUUID
                  serviceUUID:(NSString *)serviceUUID
                  characteristicUUID:(NSString *)characteristicUUID
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    BLECommandContext *context = [self getData:deviceUUID
                             serviceUUIDString:serviceUUID
                      characteristicUUIDString:characteristicUUID
                                          prop:CBCharacteristicPropertyNotify
                                  failCallback:reject];

    if (context) {
        CBPeripheral *peripheral = context.peripheral;
        CBCharacteristic *characteristic = context.characteristic;

        NSString *key = [self keyForPeripheral:peripheral andCharacteristic:characteristic];
        [notificationCallbacks setObject:resolve forKey:key];

        [peripheral setNotifyValue:YES forCharacteristic:characteristic];
    }
}

RCT_EXPORT_METHOD(stopNotification:(NSString *)deviceUUID
                  serviceUUID:(NSString *)serviceUUID
                  characteristicUUID:(NSString *)characteristicUUID
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    BLECommandContext *context = [self getData:deviceUUID
                             serviceUUIDString:serviceUUID
                      characteristicUUIDString:characteristicUUID
                                          prop:CBCharacteristicPropertyNotify
                                  failCallback:reject];

    if (context) {
        CBPeripheral *peripheral = context.peripheral;
        CBCharacteristic *characteristic = context.characteristic;

        NSString *key = [self keyForPeripheral:peripheral andCharacteristic:characteristic];
        [stopNotificationCallbacks setObject:resolve forKey:key];

        if ([characteristic isNotifying]) {
            [peripheral setNotifyValue:NO forCharacteristic:characteristic];
            NSLog(@"Characteristic stopped notifying");
        } else {
            NSLog(@"Characteristic is not notifying");
        }
    }
}

// Find a characteristic in service with a specific property
- (CBCharacteristic *)findCharacteristicFromUUID:(CBUUID *)UUID
                                         service:(CBService *)service
                                            prop:(CBCharacteristicProperties)prop {
    for (int i = 0; i < [service.characteristics count]; i++) {
        CBCharacteristic *c = [service.characteristics objectAtIndex:i];
        if ((c.properties & prop) != 0x0 && [c.UUID.UUIDString isEqualToString: UUID.UUIDString]) {
            return c;
        }
    }
    return nil; //Characteristic with prop not found on this service
}

// Find a characteristic in service by UUID
- (CBCharacteristic *)findCharacteristicFromUUID:(CBUUID *)UUID service:(CBService *)service {
    for (int i = 0; i < [service.characteristics count]; i++) {
        CBCharacteristic *c = [service.characteristics objectAtIndex:i];
        if ([c.UUID.UUIDString isEqualToString: UUID.UUIDString]) {
            return c;
        }
    }

    return nil; //Characteristic not found on this service
}

// expecting deviceUUID, serviceUUID, characteristicUUID in command.arguments
- (BLECommandContext *)getData:(NSString *)deviceUUIDString
             serviceUUIDString:(NSString *)serviceUUIDString
      characteristicUUIDString:(NSString *)characteristicUUIDString
                          prop:(CBCharacteristicProperties)prop
                  failCallback:(RCTPromiseRejectBlock)failCallback {
    CBUUID *serviceUUID = [CBUUID UUIDWithString:serviceUUIDString];
    CBUUID *characteristicUUID = [CBUUID UUIDWithString:characteristicUUIDString];

    CBPeripheral *peripheral = [self findPeripheralByUUID:deviceUUIDString];

    if (!peripheral) {
        NSString* err = [NSString stringWithFormat:@"Could not find peripherial with UUID %@", deviceUUIDString];
        NSLog(@"Could not find peripherial with UUID %@", deviceUUIDString);
        failCallback(@"BLE_PERIPHERAL_NOT_FOUND", err, nil);

        return nil;
    }

    CBService *service = [self findServiceFromUUID:serviceUUID p:peripheral];

    if (!service) {
        NSString *err = [NSString stringWithFormat:@"Could not find service with UUID %@ on peripheral with UUID %@",
                         serviceUUIDString,
                         peripheral.identifier.UUIDString];
        NSLog(@"Could not find service with UUID %@ on peripheral with UUID %@",
              serviceUUIDString,
              peripheral.identifier.UUIDString);
        failCallback(@"BLE_SERVICE_NOT_FOUND", err, nil);
        return nil;
    }

    CBCharacteristic *characteristic = [self findCharacteristicFromUUID:characteristicUUID service:service prop:prop];

    // Special handling for INDICATE. If charateristic with notify is not found, check for indicate.
    if (prop == CBCharacteristicPropertyNotify && !characteristic) {
        characteristic = [self findCharacteristicFromUUID:characteristicUUID
                                                  service:service
                                                     prop:CBCharacteristicPropertyIndicate];
    }

    // As a last resort, try and find ANY characteristic with this UUID, even if it doesn't have the correct properties
    if (!characteristic) {
        characteristic = [self findCharacteristicFromUUID:characteristicUUID service:service];
    }

    if (!characteristic) {
        NSString *err = [NSString stringWithFormat:@"Could not find characteristic with UUID %@ on service with UUID %@ on peripheral with UUID %@", characteristicUUIDString,serviceUUIDString, peripheral.identifier.UUIDString];
        NSLog(@"Could not find characteristic with UUID %@ on service with UUID %@ on peripheral with UUID %@",
              characteristicUUIDString,
              serviceUUIDString,
              peripheral.identifier.UUIDString);
        failCallback(@"BLE_CHARACTERISTIC_NOT_FOUND", err, nil);
        return nil;
    }

    BLECommandContext *context = [[BLECommandContext alloc] init];
    [context setPeripheral:peripheral];
    [context setService:service];
    [context setCharacteristic:characteristic];

    return context;
}

- (NSString *)keyForPeripheral:(CBPeripheral *)peripheral andCharacteristic:(CBCharacteristic *)characteristic {
    return [NSString stringWithFormat:@"%@|%@", peripheral.uuidAsString, [characteristic UUID]];
}

RCT_EXPORT_METHOD(retrieveConnectedPeripheralsWithServices:(NSArray *)serviceUUIDStrings
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    NSArray *services = [RCTConvert NSArray:serviceUUIDStrings];
    NSMutableArray *serviceUUIDs = [NSMutableArray new];

    for (int i = 0; i < [services count]; i++) {
        CBUUID *serviceUUID = [CBUUID UUIDWithString:[serviceUUIDStrings objectAtIndex:i]];
        [serviceUUIDs addObject:serviceUUID];
    }

    NSArray *connectedPeripherals = [self.manager retrieveConnectedPeripheralsWithServices:serviceUUIDs];
    NSMutableArray *connectedPeripheralUUIDs = [NSMutableArray new];
    for (CBPeripheral *peripheral in connectedPeripherals) {
        [connectedPeripheralUUIDs addObject:[peripheral asDictionary]];
        
        if (![self.peripherals containsObject:peripheral]) {
            [self.peripherals addObject:peripheral];
        }
    }
    
    resolve(connectedPeripheralUUIDs);
}

@end
