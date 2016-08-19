#import <CoreBluetooth/CoreBluetooth.h>
#import "RCTEventEmitter.h"

@interface BleManager : RCTEventEmitter <CBCentralManagerDelegate, CBPeripheralDelegate> {
    NSString *discoverPeripherialCallbackId;
    NSMutableDictionary *connectCallbacks;
    NSMutableDictionary *readCallbacks;
    NSMutableDictionary *writeCallbacks;
    NSMutableArray *writeQueue;
    NSMutableDictionary *notificationCallbacks;
    NSMutableDictionary *stopNotificationCallbacks;
    NSMutableDictionary *connectCallbackLatches;
    bool isObserved;
}

@property (strong, nonatomic) NSMutableSet *peripherals;
@property (strong, nonatomic) CBCentralManager *manager;

@end
