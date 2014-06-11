//
//  AudioSessionManager.m
//
//  Copyright 2011 Jawbone Inc.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//
#import "AudioSessionManager.h"

@interface AudioSessionManager () { // private

    BOOL         mBluetoothDeviceAvailable;
    BOOL         mHeadsetDeviceAvailable;
    NSArray     *mAvailableAudioDevices;
}

@property (nonatomic, assign)       BOOL             bluetoothDeviceAvailable;
@property (nonatomic, assign)       BOOL             headsetDeviceAvailable;
@property (nonatomic, strong)       NSArray         *availableAudioDevices;

@property (nonatomic, strong)       AVAudioSession  *mAudioSession;
@property (nonatomic, strong)       NSString        *mCategory;
@property (nonatomic, strong)       NSString        *mMode;

@end

NSString *kAudioSessionManagerDevice_Phone      = @"AudioSessionManagerDevice_Phone";
NSString *kAudioSessionManagerDevice_Speaker    = @"AudioSessionManagerDevice_Speaker";
NSString *kAudioSessionManagerDevice_Headset    = @"AudioSessionManagerDevice_Headset";
NSString *kAudioSessionManagerDevice_Bluetooth  = @"AudioSessionManagerDevice_Bluetooth";

// use normal logging if custom macros don't exist
#ifndef NSLogWarn
    #define NSLogWarn NSLog
#endif

#ifndef NSLogError
    #define NSLogError NSLog
#endif

#ifndef NSLogDebug
    #define AUDIO_SESSION_MANAGER_LOG_LEVEL 3
    #define NSLogDebug(frmt, ...)    do{ if(AUDIO_SESSION_MANAGER_LOG_LEVEL >= 4) NSLog((frmt), ##__VA_ARGS__); } while(0)
#endif

@implementation AudioSessionManager

@synthesize delegate;

@synthesize headsetDeviceAvailable      = mHeadsetDeviceAvailable;
@synthesize bluetoothDeviceAvailable    = mBluetoothDeviceAvailable;
@synthesize availableAudioDevices       = mAvailableAudioDevices;

#pragma mark -
#pragma mark Singleton

#define SYNTHESIZE_SINGLETON_FOR_CLASS(classname) \
+ (classname*)sharedInstance { \
static classname* __sharedInstance; \
static dispatch_once_t onceToken; \
dispatch_once(&onceToken, ^{ \
__sharedInstance = [[classname alloc] init]; \
}); \
return __sharedInstance; \
}

SYNTHESIZE_SINGLETON_FOR_CLASS(AudioSessionManager);

- (id)init {
    if ((self = [super init])) {
        _mAudioSession = [AVAudioSession sharedInstance];
    }
    return self;
}

- (void)dealloc {
    
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark public methods
- (void)start {
    // default setup
    [self start:AVAudioSessionCategoryPlayAndRecord withMode:AVAudioSessionModeVoiceChat];
}

- (void)start:(NSString *)audioSessionCategory withMode:(NSString *)audioSessionMode {
    _mCategory = audioSessionCategory ? audioSessionCategory : AVAudioSessionCategoryPlayAndRecord;
    _mMode = audioSessionMode? audioSessionMode : AVAudioSessionModeDefault;
    
    [self detectAvailableDevices];
    [[AVAudioSession sharedInstance] setMode:_mMode error:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(currentRouteChanged:)
                                                 name:AVAudioSessionRouteChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(interruptionHandler:)
                                                 name:AVAudioSessionInterruptionNotification
                                               object:nil];
}

- (BOOL)changeCategory:(NSString *)value {
    _mCategory = value;
    
    if ([[[AVAudioSession sharedInstance] category] isEqualToString:value]) {
        return YES;
    }
    return [self updateCategory];
}

- (void)refreshAudioSession:(BOOL)checkAvailableAudioDevices {
    [self updateCategory];
    [[AVAudioSession sharedInstance] setMode:_mMode error:nil];
    
    
    if (checkAvailableAudioDevices) {
        // reset
        self.headsetDeviceAvailable = NO;
        self.bluetoothDeviceAvailable = NO;
        
        // By checking currentRoute, we assume the AudioSession is already active
        AVAudioSessionRouteDescription *currentRoute = [_mAudioSession currentRoute];
        for (AVAudioSessionPortDescription *output in currentRoute.outputs) {
            if ([[output portType] isEqualToString:AVAudioSessionPortHeadphones]) {
                self.headsetDeviceAvailable = YES;
            } else if ([self isBluetoothDevice:[output portType]]) {
                self.bluetoothDeviceAvailable = YES;
            }
        }
        // In case both headphones and bluetooth are connected, detect bluetooth by inputs
        // Condition: iOS7 and Bluetooth input available
        if ([_mAudioSession respondsToSelector:@selector(availableInputs)]) {
            for (AVAudioSessionPortDescription *input in [_mAudioSession availableInputs]){
                if ([self isBluetoothDevice:[input portType]]){
                    self.bluetoothDeviceAvailable = YES;
                    break;
                }
            }
        }
    }
}

#pragma mark public properties

- (NSString *)audioRoute {
    AVAudioSessionRouteDescription *currentRoute = [[AVAudioSession sharedInstance] currentRoute];
    NSString *output = [[currentRoute.outputs objectAtIndex:0] portType];
    
    if ([output isEqualToString:AVAudioSessionPortBuiltInReceiver]) {
        return kAudioSessionManagerDevice_Phone;
    } else if ([output isEqualToString:AVAudioSessionPortBuiltInSpeaker]) {
        return kAudioSessionManagerDevice_Speaker;
    } else if ([output isEqualToString:AVAudioSessionPortHeadphones]) {
        return kAudioSessionManagerDevice_Headset;
    } else if ([self isBluetoothDevice:output]) {
        return kAudioSessionManagerDevice_Bluetooth;
    } else {
        return @"Unknown Device";
    }
}

- (void)setAudioRoute:(NSString *)audioRoute {
    if ([self audioRoute] == audioRoute) {
        return;
    }
    
    [self configureAudioSessionWithDesiredAudioRoute:audioRoute];
}

- (BOOL)phoneDeviceAvailable {
    // TODO: iPod does not have built-in receiver
    return YES;
}

- (BOOL)speakerDeviceAvailable {
    return YES;
}

- (void)setHeadsetDeviceAvailable:(BOOL)value {
    if (mHeadsetDeviceAvailable == value) {
        return;
    }
    
    mHeadsetDeviceAvailable = value;
    
    self.availableAudioDevices = nil;
}

- (void)setBluetoothDeviceAvailable:(BOOL)value {
    if (mBluetoothDeviceAvailable == value) {
        return;
    }
    
    mBluetoothDeviceAvailable = value;
    
    self.availableAudioDevices = nil;
}

- (NSArray *)availableAudioDevices {
    if (!mAvailableAudioDevices) {
        NSMutableArray *devices = [[NSMutableArray alloc] initWithCapacity:4];
        
        if (self.bluetoothDeviceAvailable)
            [devices addObject:kAudioSessionManagerDevice_Bluetooth];
        
        if (self.headsetDeviceAvailable)
            [devices addObject:kAudioSessionManagerDevice_Headset];
        
        if (self.speakerDeviceAvailable)
            [devices addObject:kAudioSessionManagerDevice_Speaker];
        
        if (self.phoneDeviceAvailable)
            [devices addObject:kAudioSessionManagerDevice_Phone];
        
        self.availableAudioDevices = devices;
    }
    
    return mAvailableAudioDevices;
}

#pragma mark private functions
- (BOOL)detectAvailableDevices {

    NSError *err;
    
    // close down our current session...
    [_mAudioSession setActive:NO error:&err];
    if (err && err.code == AVAudioSessionErrorCodeIsBusy) {
        NSLogDebug(@"===== AudioSession is running/paused ====");
    }
    
    // ===== OPEN a new audio session. Without activation, the default route will always be (inputs: null, outputs: Speaker)
    [_mAudioSession setActive:YES error:nil];
    
    // Open a session and see what our default is...
    if (![self updateCategory]) {
        return NO;
    }
    
    // Check for a wired headset...
    AVAudioSessionRouteDescription *currentRoute = [_mAudioSession currentRoute];
    for (AVAudioSessionPortDescription *output in currentRoute.outputs) {
        if ([[output portType] isEqualToString:AVAudioSessionPortHeadphones]) {
            self.headsetDeviceAvailable = YES;
        } else if ([self isBluetoothDevice:[output portType]]) {
            self.bluetoothDeviceAvailable = YES;
        }
    }
    // In case both headphones and bluetooth are connected, detect bluetooth by inputs
    // Condition: iOS7 and Bluetooth input available
    if ([_mAudioSession respondsToSelector:@selector(availableInputs)]) {
        for (AVAudioSessionPortDescription *input in [_mAudioSession availableInputs]){
            if ([self isBluetoothDevice:[input portType]]){
                self.bluetoothDeviceAvailable = YES;
                break;
            }
        }
    }
    // ===== CLOSE session after device checking
    [_mAudioSession setActive:NO error:&err];
    
    if (self.headsetDeviceAvailable) {
        NSLogDebug(@"Found Headset");
    }
    
    if (self.bluetoothDeviceAvailable) {
        NSLogDebug(@"Found Bluetooth");
    }
    
    NSLogDebug(@"AudioSession Category: %@, Mode: %@, Current Route: %@", [_mAudioSession category], _mAudioSession.mode, _mAudioSession.currentRoute);
    
    return YES;
}

- (BOOL)configureAudioSessionWithDesiredAudioRoute:(NSString *)desiredAudioRoute {

    NSError *err;
    
    // close down our current session...
    [_mAudioSession setActive:NO error:&err];
    
    if ((_mCategory == AVAudioSessionCategoryPlayAndRecord) && !_mAudioSession.inputAvailable) {
        NSLogWarn(@"device does not support recording");
        return NO;
    }
    
    /*
     * Need to always use AVAudioSessionCategoryPlayAndRecord to redirect output audio per
     * the "Audio Session Programming Guide", so we only use AVAudioSessionCategoryPlayback when
     * !inputIsAvailable - which should only apply to iPod Touches without external mics.
     */
    if (![self updateCategory]) {
        return NO;
    }
    
    /*
     * For now, we can only control output route to default (whichever output with higher priority) or Speaker
     */
    if (desiredAudioRoute == kAudioSessionManagerDevice_Speaker) {
        [_mAudioSession overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker error:&err];
    } else {
        [_mAudioSession overrideOutputAudioPort:AVAudioSessionPortOverrideNone error:&err];
    }
    if (err) {
        NSLogWarn(@"unable to override output: %@", err);
    }
    
    // Set our session to active...
    if (![_mAudioSession setActive:YES error:&err]) {
        NSLogWarn(@"unable to set audio session active: %@", err);
        return NO;
    }
    
    // Display our current route...
    NSLogDebug(@"current route: %@", self.audioRoute);
    
    return YES;
}

- (BOOL)updateCategory {
    NSError *err;
    
    if (_mAudioSession.inputAvailable && [_mCategory isEqualToString:AVAudioSessionCategoryPlayAndRecord]) {
        [_mAudioSession setCategory:AVAudioSessionCategoryPlayAndRecord withOptions:AVAudioSessionCategoryOptionAllowBluetooth error:&err];
    } else {
        [_mAudioSession setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionDuckOthers error:&err];
    }
    if (err) {
        NSLogWarn(@"unable to set audioSession category: %@", err);
        return NO;
    }
    return YES;
}

- (BOOL)isBluetoothDevice:(NSString*)portType {
    BOOL isBluetooth;
    isBluetooth = ([portType isEqualToString:AVAudioSessionPortBluetoothA2DP] ||
                   [portType isEqualToString:AVAudioSessionPortBluetoothHFP]);
    
    if ([[[UIDevice currentDevice] systemVersion] integerValue] > 6) {
        isBluetooth = (isBluetooth || [portType isEqualToString:AVAudioSessionPortBluetoothLE]);
    }
    
    return isBluetooth;
}

#pragma mark Notification Handler

- (void)currentRouteChanged:(NSNotification *)notification {
    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    
    NSInteger changeReason = [[notification.userInfo objectForKey:AVAudioSessionRouteChangeReasonKey] integerValue];
    
    AVAudioSessionRouteDescription *oldRoute = [notification.userInfo objectForKey:AVAudioSessionRouteChangePreviousRouteKey];
    NSString *oldOutput = [[oldRoute.outputs objectAtIndex:0] portType];
    AVAudioSessionRouteDescription *newRoute = [audioSession currentRoute];
    NSString *newOutput = [[newRoute.outputs objectAtIndex:0] portType];

    switch (changeReason) {
        case AVAudioSessionRouteChangeReasonOldDeviceUnavailable:
        {
            if ([oldOutput isEqualToString:AVAudioSessionPortHeadphones]) {
                
                self.headsetDeviceAvailable = NO;
                // Special Scenario:
                // when headphones are plugged in before the call and plugged out during the call
                // route will change to {input: MicrophoneBuiltIn, output: Receiver}
                // manually refresh session and support all devices again.
                [self updateCategory];
                [audioSession setMode:_mMode error:nil];
                [audioSession setActive:YES error:nil];
                
            } else if ([self isBluetoothDevice:oldOutput]) {
                
                BOOL showBluetooth = NO;
                // Additional checking for iOS7 devices (more accurate)
                // when multiple blutooth devices connected, one is no longer available does not mean no bluetooth available
                if ([audioSession respondsToSelector:@selector(availableInputs)]) {
                    NSArray *inputs = [audioSession availableInputs];
                    for (AVAudioSessionPortDescription *input in inputs){
                        if ([self isBluetoothDevice:[input portType]]){
                            showBluetooth = YES;
                            break;
                        }
                    }
                }
                if (!showBluetooth) {
                    self.bluetoothDeviceAvailable = NO;
                }
            }
        }
            break;
            
        case AVAudioSessionRouteChangeReasonNewDeviceAvailable:
        {
            if ([self isBluetoothDevice:newOutput]) {
                self.bluetoothDeviceAvailable = YES;
            } else if ([newOutput isEqualToString:AVAudioSessionPortHeadphones]) {
                self.headsetDeviceAvailable = YES;
            }
        }
            break;
            
        case AVAudioSessionRouteChangeReasonOverride:
        {
            if ([self isBluetoothDevice:oldOutput]) {
                if ([audioSession respondsToSelector:@selector(availableInputs)]) {
                    BOOL showBluetooth = NO;
                    NSArray *inputs = [audioSession availableInputs];
                    for (AVAudioSessionPortDescription *input in inputs){
                        if ([self isBluetoothDevice:[input portType]]){
                            showBluetooth = YES;
                            break;
                        }
                    }
                    if (!showBluetooth) {
                        self.bluetoothDeviceAvailable = NO;
                    }
                } else if ([newOutput isEqualToString:AVAudioSessionPortBuiltInReceiver]) {
                    
                    self.bluetoothDeviceAvailable = NO;
                }
            }
        }
            break;
            
        default:
            break;
    }
}

- (void)interruptionHandler:(NSNotification *)notification {
    NSInteger state = [[notification.userInfo objectForKey:AVAudioSessionInterruptionOptionKey] integerValue];
    NSLogDebug(@"===== Interruption State: %ld", (long)state);
    
    // The InterruptionType name is a bit misleading here
    switch (state) {
        case AVAudioSessionInterruptionTypeBegan:
        {
            if ([delegate respondsToSelector:@selector(interruptionBegan)]) {
                [delegate interruptionBegan]; // this is fired when your app audio session is going to re-start
            }
        }
            break;
            
        case AVAudioSessionInterruptionTypeEnded:
        {
            if ([delegate respondsToSelector:@selector(interruptionEnded)]) {
                [delegate interruptionEnded]; // this is fired when your app audio session is ended.
            }
        }
            break;
            
        default:
            break;
    }
}
@end

