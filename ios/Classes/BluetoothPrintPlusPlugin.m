#import "BluetoothPrintPlusPlugin.h"
#import "ConnecterManager.h"
#import "EscCommand.h"
#import "TscCommand.h"
#import "TscCommandPlugin.h"
#import "CpclCommandPlugin.h"
#import "EscCommandPlugin.h"

#define WeakSelf(type) __weak typeof(type) weak##type = type

typedef NS_ENUM(NSInteger, BPPState) {
    BlueOn = 0,
    BlueOff,
    DeviceConnected,
    DeviceDisconnected,
    DeviceError
};

@interface BluetoothPrintPlusPlugin () <CBPeripheralDelegate>

@property(nonatomic, retain) NSObject<FlutterPluginRegistrar> *registrar;
@property(nonatomic, retain) FlutterMethodChannel *channel;
@property(nonatomic, retain) BluetoothPrintStreamHandler *stateStreamHandler;
@property(nonatomic, assign) BPPState stateID;
@property(nonatomic) NSMutableDictionary *scannedPeripherals;
@property(nonatomic, assign) BOOL isBluetoothInitialized;
@property(nonatomic, assign) BOOL isScanPending;
@property(nonatomic, assign) BOOL isConnecting;
@property(nonatomic, strong) CBCentralManager *centralManager;
@property(nonatomic, strong) NSTimer *connectTimeoutTimer;
// Cached write characteristic resolved at connect time.
@property(nonatomic, strong) CBCharacteristic *cachedWriteChar;
// Semaphore signalled by didWriteValueForCharacteristic — one per ACK.
@property(nonatomic, strong) dispatch_semaphore_t writeSemaphore;
// Original peripheral delegate (BLEConnecter) saved while we intercept writes.
@property(nonatomic, weak) id<CBPeripheralDelegate> originalPeripheralDelegate;
// Serial queue — guarantees writes never overlap even if Flutter calls write()
// multiple times before the previous job finishes.
@property(nonatomic, strong) dispatch_queue_t writeQueue;

@end

@implementation BluetoothPrintPlusPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
    BluetoothPrintPlusPlugin* instance = [[BluetoothPrintPlusPlugin alloc] init];

    FlutterMethodChannel* channel = [FlutterMethodChannel
                                     methodChannelWithName:@"bluetooth_print_plus/methods"
                                     binaryMessenger:[registrar messenger]];
    instance.channel = channel;
    [registrar addMethodCallDelegate:instance channel:channel];

    FlutterEventChannel* stateChannel = [FlutterEventChannel eventChannelWithName:@"bluetooth_print_plus/state" binaryMessenger:[registrar messenger]];
    //STATE
    BluetoothPrintStreamHandler* stateStreamHandler = [[BluetoothPrintStreamHandler alloc] init];
    [stateChannel setStreamHandler:stateStreamHandler];
    instance.stateStreamHandler = stateStreamHandler;

    instance.scannedPeripherals = [NSMutableDictionary new];
    
    FlutterMethodChannel *blueChannel = [FlutterMethodChannel methodChannelWithName:@"bluetooth_print_plus"
                                                                    binaryMessenger:[registrar messenger]];
    [registrar addMethodCallDelegate:instance channel:blueChannel];
    
    FlutterMethodChannel *tscChannel = [FlutterMethodChannel methodChannelWithName:@"bluetooth_print_plus_tsc" binaryMessenger:[registrar messenger]];
    TscCommandPlugin *tsc = [[TscCommandPlugin alloc] init];
    [registrar addMethodCallDelegate:tsc channel:tscChannel];
    
    FlutterMethodChannel *cpclChannel = [FlutterMethodChannel methodChannelWithName:@"bluetooth_print_plus_cpcl" binaryMessenger:[registrar messenger]];
    CpclCommandPlugin *cpcl = [CpclCommandPlugin new];
    [registrar addMethodCallDelegate:cpcl channel:cpclChannel];
    
    FlutterMethodChannel *escChannel = [FlutterMethodChannel methodChannelWithName:@"bluetooth_print_plus_esc" binaryMessenger:[registrar messenger]];
    EscCommandPlugin *esc = [EscCommandPlugin new];
    [registrar addMethodCallDelegate:esc channel:escChannel];
    
    instance.stateID = BlueOff;
    instance.isBluetoothInitialized = NO;
    instance.isScanPending = NO;

    instance.writeQueue = dispatch_queue_create("com.bluetoothprintplus.writequeue", DISPATCH_QUEUE_SERIAL);
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    WeakSelf(self);
    printf("[BluetoothPrintPlus] 📥 handleMethodCall: %s\n", [call.method UTF8String]);
    fflush(stdout);

    if ([@"getPlatformVersion" isEqualToString:call.method]) {
        result([@"iOS " stringByAppendingString:[[UIDevice currentDevice] systemVersion]]);
    }
    else if ([@"initBluetooth" isEqualToString:call.method]) {
        [self initBluetooth];
        result(nil);
    }
    else if ([@"state" isEqualToString:call.method]) {
        [self initBluetooth];
        result([NSNumber numberWithInteger:self.stateID]);
    }
    else if([@"startScan" isEqualToString:call.method]) {
        [self initBluetooth];
        // Do NOT clear scannedPeripherals here — the Flutter UI may still hold
        // references to previously scanned devices. Clearing causes "not found"
        // errors when the user taps connect on a device from a prior scan session.
        // Entries are keyed by UUID so there is no risk of duplication.
        if (self.stateID == BlueOn || self.stateID == DeviceConnected || self.stateID == DeviceDisconnected) {
            [self startScan];
        } else {
            self.isScanPending = YES;
        }
        result(nil);
    }
    else if([@"stopScan" isEqualToString:call.method]) {
        self.isScanPending = NO;
        [Manager stopScan];
        result(nil);
    }
    else if([@"connect" isEqualToString:call.method]) {
        [self initBluetooth];
        [Manager stopScan];
        NSDictionary *device = [call arguments];
        NSString *address = [device objectForKey:@"address"];
        self.isConnecting = YES; // Set flag to suppress initial disconnects

        @try {
            printf("[BluetoothPrintPlus] 🔗 Attempting to connect to: %s (%s)\n", [[device objectForKey:@"name"] UTF8String], [address UTF8String]);
            fflush(stdout);

            CBPeripheral *peripheral = [_scannedPeripherals objectForKey:address];

            // Fallback 1: check the currently-connected peripheral held by the Manager
            if (!peripheral && Manager.peripheral) {
                if ([Manager.peripheral.identifier.UUIDString isEqualToString:address]) {
                    peripheral = Manager.peripheral;
                    [_scannedPeripherals setObject:peripheral forKey:address];
                    printf("[BluetoothPrintPlus] ℹ️ Peripheral recovered from Manager.peripheral\n");
                }
            }

            // Fallback 2: check the peripheral stored inside the BLE connecter
            if (!peripheral && Manager.bleConnecter.connPeripheral) {
                if ([Manager.bleConnecter.connPeripheral.identifier.UUIDString isEqualToString:address]) {
                    peripheral = Manager.bleConnecter.connPeripheral;
                    [_scannedPeripherals setObject:peripheral forKey:address];
                    printf("[BluetoothPrintPlus] ℹ️ Peripheral recovered from bleConnecter.connPeripheral\n");
                }
            }

            // Fallback 3: ask iOS system directly using a temporary central manager
            if (!peripheral) {
                NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:address];
                if (uuid) {
                    // Create a one-time manager just to retrieve the peripheral object
                    CBCentralManager *tempManager = [[CBCentralManager alloc] initWithDelegate:nil queue:nil];
                    NSArray<CBPeripheral *> *found = [tempManager retrievePeripheralsWithIdentifiers:@[uuid]];
                    if (found.count > 0) {
                        peripheral = found.firstObject;
                        [_scannedPeripherals setObject:peripheral forKey:address];
                        printf("[BluetoothPrintPlus] ℹ️ Peripheral recovered from iOS system cache via Temp CM\n");
                    }
                }
            }

            if (!peripheral) {
                printf("[BluetoothPrintPlus] ❌ Error: Peripheral not found — please scan first.\n");
                fflush(stdout);
                result([FlutterError errorWithCode:@"device_not_found" message:@"Device not found. Please scan for devices first." details:nil]);
                return;
            }

            printf("[BluetoothPrintPlus] 🚀 EXECUTING connectPeripheral for: %s\n", [peripheral.identifier.UUIDString UTF8String]);
            fflush(stdout);

            __block BOOL isResultSent = NO;

            // Khởi động Timer thủ công đề phòng lib Tàu im lặng
            [self.connectTimeoutTimer invalidate];
            self.connectTimeoutTimer = [NSTimer scheduledTimerWithTimeInterval:7.5 repeats:NO block:^(NSTimer * _Nonnull timer) {
                if (!isResultSent) {
                    printf("[BluetoothPrintPlus] 🕒 Manual Timeout Triggered (7.5s)\n");
                    fflush(stdout);

                    // Khi timeout, ta phải giải phóng cờ isConnecting để cho phép gửi trạng thái ngắt
                    weakself.isConnecting = NO;
                    [weakself updateConnectState:CONNECT_STATE_DISCONNECT];

                    isResultSent = YES;
                    result([FlutterError errorWithCode:@"connect_timeout" message:@"Connection timed out" details:nil]);
                }
            }];

            self.state = ^(ConnectState state) {
                // Luôn gọi updateConnectState để đồng bộ hóa isConnecting và filtering
                [weakself updateConnectState:state];

                if (state == CONNECT_STATE_CONNECTED) {
                    // Thành công -> Hủy Timer và tắt cờ chặn
                    [weakself.connectTimeoutTimer invalidate];
                    weakself.connectTimeoutTimer = nil;
                    weakself.isConnecting = NO;

                    printf("[BluetoothPrintPlus] 🎊 Bluetooth link established.\n");
                    fflush(stdout);

                    Manager.currentConnMethod = BLUETOOTH;
                    Manager.type = TSC;

                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        // ── Tìm và Cache characteristic để in ───────────────────
                        if (Manager.peripheral) {
                            for (CBService *svc in Manager.peripheral.services) {
                                for (CBCharacteristic *ch in svc.characteristics) {
                                    CBCharacteristicProperties props = ch.properties;
                                    if ((props & CBCharacteristicPropertyWrite) || (props & CBCharacteristicPropertyWriteWithoutResponse)) {
                                        weakself.cachedWriteChar = ch;
                                        printf("[BluetoothPrintPlus] 📌 Cached write char: %s\n", [ch.UUID.UUIDString UTF8String]);
                                        break;
                                    }
                                }
                                if (weakself.cachedWriteChar) break;
                            }
                        }

                        if (!isResultSent) {
                            isResultSent = YES;
                            printf("[BluetoothPrintPlus] ✅ SDK Ready to receive data!\n");
                            fflush(stdout);
                            result(nil);
                        }
                    });
                } else if (state == CONNECT_STATE_DISCONNECT) {
                    if (!weakself.isConnecting) { // Chỉ trả kết quả về Dart nếu không còn đang đợi connect (đã timeout hoặc lỗi thật)
                        [weakself.connectTimeoutTimer invalidate];
                        weakself.connectTimeoutTimer = nil;
                        if (!isResultSent) {
                            isResultSent = YES;
                            result([FlutterError errorWithCode:@"connect_failed" message:@"Connection failed" details:nil]);
                        }
                    }
                }
            };
            [Manager connectPeripheral:peripheral options:nil timeout:7 connectBlack: self.state];
        } @catch(NSException *e) {
            result([FlutterError errorWithCode:@"connect_error" message:e.reason details:nil]);
        }
    }
    else if([@"disconnect" isEqualToString:call.method]) {
        [Manager close];
        self.cachedWriteChar = nil;
        result(nil);
    }
    else if([@"write" isEqualToString:call.method]) {
        @try {
            NSDictionary *args = [call arguments];
            FlutterStandardTypedData *command = [args objectForKey:@"data"];
            NSData *allData = command.data;

            printf("[BluetoothPrintPlus] 📝 Write request: %lu bytes\n", (unsigned long)allData.length);

            if (!Manager.isConnected) {
                printf("[BluetoothPrintPlus] ❌ Error: Manager is not connected.\n");
                result([FlutterError errorWithCode:@"not_connected" message:@"Not connected" details:nil]);
                return;
            }

            // Use the write characteristic cached at connect time.
            // If somehow nil (reconnected without going through connect flow), resolve now.
            CBCharacteristic *writeChar = self.cachedWriteChar;
            if (!writeChar) {
                printf("[BluetoothPrintPlus] ⚠️ No cached write char — reconnect to printer.\n");
                fflush(stdout);
                result([FlutterError errorWithCode:@"not_ready"
                                           message:@"No writable BLE characteristic found. Reconnect and try again."
                                           details:nil]);
                return;
            }

            CBCharacteristicProperties props = writeChar.properties;
            BOOL supportsWithResponse = (props & CBCharacteristicPropertyWrite) != 0;

            // Use the actual negotiated MTU instead of the conservative 20-byte default.
            // iOS exposes maximumWriteValueLengthForType: which accounts for MTU negotiation.
            // Typical values after negotiation: 182 bytes (iPhone) or up to 244 bytes.
            CBCharacteristicWriteType writeType = supportsWithResponse
                                                  ? CBCharacteristicWriteWithResponse
                                                  : CBCharacteristicWriteWithoutResponse;
            NSUInteger mtu = [Manager.peripheral maximumWriteValueLengthForType:writeType];

            printf("[BluetoothPrintPlus] 📤 Sending %lu bytes | char: %s | MTU: %lu | type: %s\n",
                   (unsigned long)allData.length,
                   [writeChar.UUID.UUIDString UTF8String],
                   (unsigned long)mtu,
                   supportsWithResponse ? "WithResponse" : "WithoutResponse");
            fflush(stdout);

            dispatch_async(self.writeQueue, ^{
                NSUInteger length = allData.length;
                NSUInteger offset = 0;
                NSUInteger totalChunks = (length + mtu - 1) / mtu;

                if (supportsWithResponse) {
                    // ── WithResponse: true ACK-based flow control ─────────────────
                    // We intercept the peripheral delegate to receive each
                    // didWriteValueForCharacteristic: ACK, then signal a semaphore.
                    // This means we wait for each chunk to be ACTUALLY SENT AND
                    // ACKNOWLEDGED before sending the next one — no timing estimates.
                    weakself.writeSemaphore = dispatch_semaphore_create(0);
                    dispatch_sync(dispatch_get_main_queue(), ^{
                        weakself.originalPeripheralDelegate = Manager.peripheral.delegate;
                        Manager.peripheral.delegate = weakself;
                    });

                    printf("[BluetoothPrintPlus] 📤 Sending %lu chunks (WithResponse + ACK semaphore)...\n",
                           (unsigned long)totalChunks);
                    fflush(stdout);

                    while (offset < length) {
                        if (!Manager.isConnected) {
                            printf("[BluetoothPrintPlus] ❌ Write interrupted: disconnected at %lu\n",
                                   (unsigned long)offset);
                            fflush(stdout);
                            break;
                        }
                        NSUInteger remaining = length - offset;
                        NSUInteger currentChunk = MIN(remaining, mtu);
                        NSData *chunk = [allData subdataWithRange:NSMakeRange(offset, currentChunk)];

                        [Manager.peripheral writeValue:chunk
                                     forCharacteristic:writeChar
                                                  type:CBCharacteristicWriteWithResponse];

                        // Block until peripheral ACKs this chunk (5s timeout per chunk)
                        long result = dispatch_semaphore_wait(
                                weakself.writeSemaphore,
                                dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)
                        );
                        if (result != 0) {
                            printf("[BluetoothPrintPlus] ⚠️ ACK timeout at offset %lu\n",
                                   (unsigned long)offset);
                            fflush(stdout);
                        }
                        offset += currentChunk;
                    }

                    // Restore original delegate
                    dispatch_sync(dispatch_get_main_queue(), ^{
                        Manager.peripheral.delegate = weakself.originalPeripheralDelegate;
                        weakself.originalPeripheralDelegate = nil;
                        weakself.writeSemaphore = nil;
                    });

                } else {
                    // ── WithoutResponse: pace with 20ms delay per chunk ───────────
                    printf("[BluetoothPrintPlus] 📤 Sending %lu chunks (WithoutResponse)...\n",
                           (unsigned long)totalChunks);
                    fflush(stdout);

                    while (offset < length) {
                        NSUInteger remaining = length - offset;
                        NSUInteger currentChunk = MIN(remaining, mtu);
                        NSData *chunk = [allData subdataWithRange:NSMakeRange(offset, currentChunk)];

                        [Manager.bleConnecter writeValue:chunk
                                       forCharacteristic:writeChar
                                                    type:CBCharacteristicWriteWithoutResponse];
                        offset += currentChunk;
                        [NSThread sleepForTimeInterval:0.02];
                    }
                }

                printf("[BluetoothPrintPlus] ✅ PrintCompleted! (%lu bytes sent)\n",
                       (unsigned long)length);
                fflush(stdout);

                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakself.channel invokeMethod:@"PrintCompleted" arguments:@YES];
                });
            });

            result(nil);
        } @catch(NSException *e) {
            printf("[BluetoothPrintPlus] ❌ Write Error: %s\n", [e.reason UTF8String]);
            fflush(stdout);
            result([FlutterError errorWithCode:@"write_error" message:e.reason details:nil]);
        }
    }
    else {
        result(FlutterMethodNotImplemented);
    }
}

- (void)initBluetooth {
    if (self.isBluetoothInitialized) {
        return;
    }
    self.isBluetoothInitialized = YES;

    WeakSelf(self);
    [Manager didUpdateState:^(NSInteger state) {
        printf("[BluetoothPrintPlus] 📡 didUpdateState: %ld\n", (long)state);
        fflush(stdout);
        dispatch_async(dispatch_get_main_queue(), ^{
            NSNumber *ret = @(BlueOff);
            switch (state) {
                case CBManagerStatePoweredOn:
                    NSLog(@"Bluetooth Powered On");
                    ret = @(BlueOn);
                    weakself.stateID = BlueOn;
                    if (weakself.isScanPending) {
                        weakself.isScanPending = NO;
                        // Tăng delay lên 1.0s để đảm bảo phần cứng sẵn sàng sau khi cấp quyền
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            [weakself startScan];
                        });
                    }
                    break;
                case CBManagerStatePoweredOff:
                    NSLog(@"Bluetooth Powered Off");
                    ret = @(BlueOff);
                    weakself.stateID = BlueOff;
                    break;
                default:
                    return;
            }
            NSDictionary *dict = [NSDictionary dictionaryWithObjectsAndKeys:ret ,@"id",nil];
            if(weakself.stateStreamHandler.sink != nil) {
                weakself.stateStreamHandler.sink([dict objectForKey:@"id"]);
            }
        });
    }];
}

-(void)startScan {
    WeakSelf(self);
    printf("[BluetoothPrintPlus] 🔍 Starting Scan...\n");
    fflush(stdout);

    // 1. Sử dụng biến tạm để tránh race condition khi Manager.peripheral thay đổi
    CBPeripheral *currentPeripheral = Manager.peripheral;
    if (currentPeripheral) {
        [self sendDeviceToFlutter:currentPeripheral name:currentPeripheral.name];
    }

    // 2. Bắt đầu quét các thiết bị đang quảng cáo xung quanh
    [Manager scanForPeripheralsWithServices:nil options:nil discover:^(CBPeripheral * _Nullable peripheral, NSDictionary<NSString *,id> * _Nullable advertisementData, NSNumber * _Nullable RSSI) {
        if (!peripheral) return; // Bảo vệ: Nếu peripheral nil thì bỏ qua ngay

        NSString *name = peripheral.name;
        if (!name || name.length == 0) {
            name = advertisementData[CBAdvertisementDataLocalNameKey];
        }

        if (name && name.length > 0) {
            [weakself sendDeviceToFlutter:peripheral name:name];
        }
    }];
}

- (void)sendDeviceToFlutter:(CBPeripheral *)peripheral name:(NSString *)name {
    if (!peripheral || !name || name.length == 0) return;

    // Lấy UUIDString an toàn
    NSString *uuid = peripheral.identifier.UUIDString;
    if (!uuid) return;

    WeakSelf(self);
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakself.scannedPeripherals setObject:peripheral forKey:uuid];
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        [dict setValue:name forKey:@"name"];
        [dict setValue:uuid forKey:@"address"];
        [dict setValue:@(0) forKey:@"type"];

        [weakself.channel invokeMethod:@"ScanResult" arguments:dict];
    });
}

-(void)updateConnectState:(ConnectState)state {
    WeakSelf(self);
    dispatch_async(dispatch_get_main_queue(), ^{
        printf("[BluetoothPrintPlus] 📡 updateConnectState raw value: %ld\n", (long)state);
        fflush(stdout);

        NSNumber *ret = nil;
        switch (state) {
            case CONNECT_STATE_CONNECTED:
                printf("[BluetoothPrintPlus] ✅ status: Connected Successful\n");
                ret = @(DeviceConnected);
                weakself.stateID = DeviceConnected;
                weakself.isConnecting = NO; // Success terminal state
                break;
            case CONNECT_STATE_DISCONNECT:
                printf("[BluetoothPrintPlus] ❌ status: Disconnected\n");
                ret = @(DeviceDisconnected);
                weakself.stateID = DeviceDisconnected;

                // Chỉ chặn sự kiện Disconnected nếu nó là cái đầu tiên ngay khi vừa bấm Connect (handshake cleanup)
                if (weakself.isConnecting) {
                    printf("[BluetoothPrintPlus] ℹ️ Suppressing handshake cleanup disconnect\n");
                    ret = nil;
                    // Do NOT set isConnecting = NO, wait for success or terminal fail
                }
                break;
            default:
                // Các trạng thái khác (Connecting, Fail, etc.)
                if (weakself.isConnecting) {
                    printf("[BluetoothPrintPlus] ℹ️ Ignoring intermediate state (%ld) during connect flow\n", (long)state);
                    ret = nil;
                    // Do NOT set isConnecting = NO, stay in connect mode
                } else {
                    printf("[BluetoothPrintPlus] ⚠️ status: Unhandled error (%ld)\n", (long)state);
                    ret = @(DeviceError);
                    weakself.stateID = DeviceError;
                }
                break;
        }

        if(ret != nil && weakself.stateStreamHandler.sink != nil) {
            weakself.stateStreamHandler.sink(ret);
        }
    });
}

@end

// ─────────────────────────────────────────────────────────────────────────────
// CBPeripheralDelegate — only active during a WithResponse write session.
// We temporarily become the peripheral delegate to receive per-chunk ACKs via
// didWriteValueForCharacteristic:, signal the write semaphore, then restore the
// original delegate (BLEConnecter) when the write loop finishes.
// All other delegate methods are forwarded to the original delegate so that
// notifications and other events are not lost during the write.
// ─────────────────────────────────────────────────────────────────────────────
@implementation BluetoothPrintPlusPlugin (PeripheralDelegate)

/// Called by CoreBluetooth when a WithResponse write is acknowledged.
- (void)peripheral:(CBPeripheral *)peripheral
didWriteValueForCharacteristic:(CBCharacteristic *)characteristic
             error:(NSError *)error {
    if (error) {
        printf("[BluetoothPrintPlus] ⚠️ Write ACK error: %s\n",
               [[error localizedDescription] UTF8String]);
        fflush(stdout);
    }
    if (self.writeSemaphore) {
        dispatch_semaphore_signal(self.writeSemaphore);
    }
}

/// Forward notify/read updates to BLEConnecter so printer responses still arrive.
- (void)peripheral:(CBPeripheral *)peripheral
didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic
             error:(NSError *)error {
    if ([self.originalPeripheralDelegate respondsToSelector:
         @selector(peripheral:didUpdateValueForCharacteristic:error:)]) {
        [self.originalPeripheralDelegate peripheral:peripheral
                   didUpdateValueForCharacteristic:characteristic
                                             error:error];
    }
}

/// Forward notification state changes to BLEConnecter.
- (void)peripheral:(CBPeripheral *)peripheral
didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic
             error:(NSError *)error {
    if ([self.originalPeripheralDelegate respondsToSelector:
         @selector(peripheral:didUpdateNotificationStateForCharacteristic:error:)]) {
        [self.originalPeripheralDelegate peripheral:peripheral
       didUpdateNotificationStateForCharacteristic:characteristic
                                             error:error];
    }
}

@end

@implementation BluetoothPrintStreamHandler
- (FlutterError*)onListenWithArguments:(id)arguments eventSink:(FlutterEventSink)eventSink {
    self.sink = eventSink;
    return nil;
}

- (FlutterError*)onCancelWithArguments:(id)arguments {
    self.sink = nil;
    return nil;
}

@end
