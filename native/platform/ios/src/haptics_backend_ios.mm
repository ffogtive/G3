// haptics_backend_ios.mm — Core Haptics + UIKit feedback backend for IOSHaptics (iOS 15+, ARC, ObjC++).
//
// 가설: ❓ CHHapticEngine 1개를 상주(autoShutdown 끔, playsHapticsOnly)시키고 패턴을 이름으로 미리 파싱해 두면
//       Godot 기본 vibrate_handheld(호출마다 엔진·패턴 생성, continuous+intensity만)보다 첫 탭 지연이 짧고
//       transient·sharpness 표현이 된다. 실기기 체감은 M1a 판정에서 확인한다.
//
// Lifecycle (Apple: "Preparing your app to play haptics", CHHapticEngine resetHandler/stoppedHandler docs):
//   start()            -> create engine once, start synchronously, remember that we want it running
//   stoppedHandler     -> mark stopped (reason kept for debug_state); next play restarts lazily
//   resetHandler       -> server reset: mark stopped and restart if wanted (patterns stay valid; players don't)
//   background         -> stop; foreground / became active -> restart if wanted
//   thermal / power    -> NSProcessInfo thermalState / lowPowerModeEnabled (+ change counter)
// All entry points run on the main thread (Godot's iOS main loop is driven by the UIKit run loop).
#import <CoreHaptics/CoreHaptics.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include "haptics_backend.h"
#include "haptics_core.h"

#include <memory>
#include <string>

@interface Lane1HapticsDriver : NSObject
- (BOOL)supported;
- (BOOL)startEngine;
- (void)stopEngine;
- (void)shutdown;
- (BOOL)transientWithIntensity:(float)intensity sharpness:(float)sharpness;
- (BOOL)continuousWithIntensity:(float)intensity sharpness:(float)sharpness duration:(NSTimeInterval)duration;
- (BOOL)registerPattern:(NSString *)name json:(NSString *)json;
- (BOOL)playRegistered:(NSString *)name;
- (BOOL)playJSON:(NSString *)json;
- (void)selection;
- (void)impactWithStyle:(NSInteger)style intensity:(CGFloat)intensity;
- (void)prepare;
- (NSString *)thermalStateName;
- (BOOL)lowPowerMode;
- (NSInteger)thermalChanges;
- (NSString *)stateFields;
@end

@implementation Lane1HapticsDriver {
	CHHapticEngine *_engine;
	NSMutableDictionary<NSString *, CHHapticPattern *> *_patterns;
	UISelectionFeedbackGenerator *_selectionGenerator;
	NSMutableDictionary<NSNumber *, UIImpactFeedbackGenerator *> *_impactGenerators;
	NSArray<id<NSObject>> *_observers;
	BOOL _supported;
	BOOL _wantRunning;
	BOOL _running;
	BOOL _inBackground;
	NSInteger _resets;
	NSInteger _stops;
	NSInteger _startFailures;
	NSInteger _playFailures;
	NSInteger _thermalChanges;
	NSInteger _lastStopReason;
	NSString *_lastError;
}

- (instancetype)init {
	if ((self = [super init])) {
		_patterns = [NSMutableDictionary dictionary];
		_impactGenerators = [NSMutableDictionary dictionary];
		_supported = [[CHHapticEngine capabilitiesForHardware] supportsHaptics];
		_lastStopReason = -1;
		_lastError = @"";
		_inBackground = [UIApplication sharedApplication].applicationState == UIApplicationStateBackground;
		[self observeNotifications];
	}
	return self;
}

- (void)dealloc {
	[self shutdown];
}

- (void)observeNotifications {
	NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
	NSOperationQueue *main = [NSOperationQueue mainQueue];
	__weak Lane1HapticsDriver *weakSelf = self;
	void (^toBackground)(NSNotification *) = ^(NSNotification *note) {
		[weakSelf appDidEnterBackground];
	};
	void (^toForeground)(NSNotification *) = ^(NSNotification *note) {
		[weakSelf appWillEnterForeground];
	};
	// Godot 4.7 apps are scene-based (UIApplicationSceneManifest); observe both the scene and the app
	// notifications. The handlers are idempotent.
	_observers = @[
		[center addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:main usingBlock:toBackground],
		[center addObserverForName:UISceneDidEnterBackgroundNotification object:nil queue:main usingBlock:toBackground],
		[center addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:main usingBlock:toForeground],
		[center addObserverForName:UISceneWillEnterForegroundNotification object:nil queue:main usingBlock:toForeground],
		[center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:main usingBlock:toForeground],
		[center addObserverForName:NSProcessInfoThermalStateDidChangeNotification
							object:nil
							 queue:main
						usingBlock:^(NSNotification *note) {
							[weakSelf thermalStateChanged];
						}],
	];
}

- (void)shutdown {
	for (id<NSObject> observer in _observers) {
		[[NSNotificationCenter defaultCenter] removeObserver:observer];
	}
	_observers = @[];
	_wantRunning = NO;
	if (_engine != nil) {
		_engine.stoppedHandler = ^(CHHapticEngineStoppedReason reason) {};
		_engine.resetHandler = ^{};
		[_engine stopWithCompletionHandler:nil];
	}
	_engine = nil;
	_running = NO;
}

- (BOOL)supported {
	return _supported;
}

- (void)noteError:(NSError *)error context:(NSString *)context {
	_lastError = [NSString stringWithFormat:@"%@: %@", context, error != nil ? error.localizedDescription : @"unknown"];
}

- (BOOL)ensureEngine {
	if (!_supported) {
		return NO;
	}
	if (_engine != nil) {
		return YES;
	}
	NSError *error = nil;
	CHHapticEngine *engine = [[CHHapticEngine alloc] initAndReturnError:&error];
	if (engine == nil) {
		[self noteError:error context:@"init"];
		return NO;
	}
	engine.playsHapticsOnly = YES; // no audio events: lower latency, no audio-session coupling
	engine.autoShutdownEnabled = NO; // first tap after an idle stretch must not pay the restart cost
	__weak Lane1HapticsDriver *weakSelf = self;
	engine.stoppedHandler = ^(CHHapticEngineStoppedReason reason) {
		dispatch_async(dispatch_get_main_queue(), ^{
			[weakSelf engineStopped:reason];
		});
	};
	engine.resetHandler = ^{
		dispatch_async(dispatch_get_main_queue(), ^{
			[weakSelf engineReset];
		});
	};
	_engine = engine;
	return YES;
}

- (BOOL)startNow {
	if (_inBackground || ![self ensureEngine]) {
		return NO;
	}
	if (_running) {
		return YES;
	}
	NSError *error = nil;
	if (![_engine startAndReturnError:&error]) {
		++_startFailures;
		[self noteError:error context:@"start"];
		_running = NO;
		return NO;
	}
	_running = YES;
	return YES;
}

- (BOOL)startEngine {
	_wantRunning = YES;
	if (_inBackground) {
		return _supported; // deferred: starts on the next foreground notification
	}
	return [self startNow];
}

- (void)stopEngine {
	_wantRunning = NO;
	if (_engine != nil && _running) {
		[_engine stopWithCompletionHandler:nil];
	}
	_running = NO;
}

- (void)engineStopped:(CHHapticEngineStoppedReason)reason {
	_running = NO;
	++_stops;
	_lastStopReason = (NSInteger)reason;
}

- (void)engineReset {
	++_resets;
	_running = NO;
	if (_wantRunning && !_inBackground) {
		[self startNow];
	}
}

- (void)appDidEnterBackground {
	if (_inBackground) {
		return;
	}
	_inBackground = YES;
	if (_engine != nil && _running) {
		[_engine stopWithCompletionHandler:nil];
	}
	_running = NO;
}

- (void)appWillEnterForeground {
	_inBackground = NO;
	if (_wantRunning) {
		[self startNow];
	}
}

- (void)thermalStateChanged {
	++_thermalChanges;
}

- (BOOL)play:(CHHapticPattern *)pattern {
	if (pattern == nil || !_supported || _inBackground) {
		return NO;
	}
	_wantRunning = YES; // playing implies the engine should stay up
	if (![self startNow]) {
		++_playFailures;
		return NO;
	}
	NSError *error = nil;
	id<CHHapticPatternPlayer> player = [_engine createPlayerWithPattern:pattern error:&error];
	if (player != nil && [player startAtTime:CHHapticTimeImmediate error:&error]) {
		return YES;
	}
	// The engine may have stopped since the last call (stoppedHandler is async): restart once and retry.
	_running = NO;
	if ([self startNow]) {
		error = nil;
		player = [_engine createPlayerWithPattern:pattern error:&error];
		if (player != nil && [player startAtTime:CHHapticTimeImmediate error:&error]) {
			return YES;
		}
	}
	++_playFailures;
	[self noteError:error context:@"play"];
	return NO;
}

- (CHHapticPattern *)patternWithEvent:(CHHapticEvent *)event {
	NSError *error = nil;
	CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithEvents:@[ event ] parameters:@[] error:&error];
	if (pattern == nil) {
		[self noteError:error context:@"pattern"];
	}
	return pattern;
}

- (NSArray<CHHapticEventParameter *> *)parametersWithIntensity:(float)intensity sharpness:(float)sharpness {
	return @[
		[[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:intensity],
		[[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:sharpness],
	];
}

- (BOOL)transientWithIntensity:(float)intensity sharpness:(float)sharpness {
	@autoreleasepool {
		CHHapticEvent *event = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticTransient
															 parameters:[self parametersWithIntensity:intensity sharpness:sharpness]
														   relativeTime:0];
		return [self play:[self patternWithEvent:event]];
	}
}

- (BOOL)continuousWithIntensity:(float)intensity sharpness:(float)sharpness duration:(NSTimeInterval)duration {
	@autoreleasepool {
		CHHapticEvent *event = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous
															 parameters:[self parametersWithIntensity:intensity sharpness:sharpness]
														   relativeTime:0
															   duration:duration];
		return [self play:[self patternWithEvent:event]];
	}
}

- (CHHapticPattern *)patternFromJSON:(NSString *)json {
	NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
	if (data == nil) {
		_lastError = @"ahap: not UTF-8";
		return nil;
	}
	NSError *error = nil;
	id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
	if (![object isKindOfClass:[NSDictionary class]]) {
		[self noteError:error context:@"ahap json"];
		return nil;
	}
	CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithDictionary:(NSDictionary *)object error:&error];
	if (pattern == nil) {
		[self noteError:error context:@"ahap pattern"];
	}
	return pattern;
}

- (BOOL)registerPattern:(NSString *)name json:(NSString *)json {
	@autoreleasepool {
		CHHapticPattern *pattern = [self patternFromJSON:json];
		if (pattern == nil) {
			return NO;
		}
		_patterns[name] = pattern;
		return YES;
	}
}

- (BOOL)playRegistered:(NSString *)name {
	@autoreleasepool {
		return [self play:_patterns[name]];
	}
}

- (BOOL)playJSON:(NSString *)json {
	@autoreleasepool {
		return [self play:[self patternFromJSON:json]];
	}
}

- (void)selection {
	if (_selectionGenerator == nil) {
		_selectionGenerator = [[UISelectionFeedbackGenerator alloc] init];
	}
	[_selectionGenerator selectionChanged];
	[_selectionGenerator prepare];
}

- (void)impactWithStyle:(NSInteger)style intensity:(CGFloat)intensity {
	NSNumber *key = @(style);
	UIImpactFeedbackGenerator *generator = _impactGenerators[key];
	if (generator == nil) {
		generator = [[UIImpactFeedbackGenerator alloc] initWithStyle:(UIImpactFeedbackStyle)style];
		_impactGenerators[key] = generator;
	}
	[generator impactOccurredWithIntensity:intensity];
	[generator prepare];
}

- (void)prepare {
	if (_selectionGenerator == nil) {
		_selectionGenerator = [[UISelectionFeedbackGenerator alloc] init];
	}
	[_selectionGenerator prepare];
	for (UIImpactFeedbackGenerator *generator in _impactGenerators.allValues) {
		[generator prepare];
	}
}

- (NSString *)thermalStateName {
	switch ([NSProcessInfo processInfo].thermalState) {
		case NSProcessInfoThermalStateNominal:
			return @"nominal";
		case NSProcessInfoThermalStateFair:
			return @"fair";
		case NSProcessInfoThermalStateSerious:
			return @"serious";
		case NSProcessInfoThermalStateCritical:
			return @"critical";
	}
	return @"unknown";
}

- (BOOL)lowPowerMode {
	return [NSProcessInfo processInfo].lowPowerModeEnabled;
}

- (NSInteger)thermalChanges {
	return _thermalChanges;
}

- (NSString *)stateFields {
	const std::string error = lane1::haptics::json_quote(std::string(_lastError.UTF8String != nullptr ? _lastError.UTF8String : ""));
	return [NSString stringWithFormat:@"\"running\":%@,\"want_running\":%@,\"background\":%@,\"resets\":%ld,\"stops\":%ld,"
									  @"\"last_stop_reason\":%ld,\"start_failures\":%ld,\"play_failures\":%ld,\"patterns\":%lu,"
									  @"\"thermal_changes\":%ld,\"last_error\":%s",
					 _running ? @"true" : @"false", _wantRunning ? @"true" : @"false", _inBackground ? @"true" : @"false",
					 (long)_resets, (long)_stops, (long)_lastStopReason, (long)_startFailures, (long)_playFailures,
					 (unsigned long)_patterns.count, (long)_thermalChanges, error.c_str()];
}

@end

namespace lane1::haptics {

namespace {

NSString *to_ns(const std::string &s) {
	NSString *out = [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding];
	return out != nil ? out : @"";
}

std::string to_std(NSString *s) {
	const char *utf8 = s.UTF8String;
	return utf8 != nullptr ? std::string(utf8) : std::string();
}

class CoreHapticsBackend final : public Backend {
public:
	CoreHapticsBackend() :
			driver_([[Lane1HapticsDriver alloc] init]) {}
	~CoreHapticsBackend() override {
		[driver_ shutdown];
		driver_ = nil;
	}

	const char *name() const override { return "corehaptics"; }
	bool is_supported() const override { return [driver_ supported]; }
	bool start() override { return [driver_ startEngine]; }
	void stop() override { [driver_ stopEngine]; }
	bool transient(double intensity, double sharpness) override {
		return [driver_ transientWithIntensity:static_cast<float>(intensity) sharpness:static_cast<float>(sharpness)];
	}
	bool continuous(double intensity, double sharpness, double duration) override {
		return [driver_ continuousWithIntensity:static_cast<float>(intensity) sharpness:static_cast<float>(sharpness) duration:duration];
	}
	bool register_pattern(const std::string &name, const std::string &ahap_json) override {
		return [driver_ registerPattern:to_ns(name) json:to_ns(ahap_json)];
	}
	bool play_registered(const std::string &name) override { return [driver_ playRegistered:to_ns(name)]; }
	bool play_pattern(const std::string &ahap_json) override { return [driver_ playJSON:to_ns(ahap_json)]; }
	void selection() override { [driver_ selection]; }
	void impact(ImpactStyle style, double intensity) override {
		[driver_ impactWithStyle:static_cast<NSInteger>(style) intensity:static_cast<CGFloat>(intensity)];
	}
	void prepare() override { [driver_ prepare]; }
	std::string thermal_state() const override { return to_std([driver_ thermalStateName]); }
	bool is_low_power_mode() const override { return [driver_ lowPowerMode]; }
	int64_t thermal_change_count() const override { return static_cast<int64_t>([driver_ thermalChanges]); }
	std::string state_fields() const override { return to_std([driver_ stateFields]); }

private:
	Lane1HapticsDriver *driver_;
};

} // namespace

std::unique_ptr<Backend> make_backend() {
	return std::make_unique<CoreHapticsBackend>();
}

} // namespace lane1::haptics
