// Copyright: 2018, Ableton AG, Berlin. All rights reserved.

#include "ABLLinkSettingsViewController.h"
#include "AudioEngine.h"
#include "ViewController.h"

@implementation TransportButton
- (BOOL)isHighlighted {
    return NO;
}
@end


@interface ViewController ()

- (void)updateSessionTempo:(Float64)bpm;
- (void)updateIsTransportOn:(BOOL)on;

@end

static void onSessionTempoChanged(Float64 bpm, void* context) {
    ViewController* vc = (__bridge ViewController *)context;
    [vc updateSessionTempo:bpm];
}

static void onStartStopStateChanged(bool on, void* context) {
   ViewController* vc = (__bridge ViewController *)context;
   [vc updateIsTransportOn:on];
 }


@implementation ViewController {
    AudioEngine *_audioEngine;
    Float64 _bpm;
    Float64 _quanta;
    UIViewController *_linkSettings;
    NSTimer *_updateBeatTimeTimer;
    NSTimer *_bpmDecreaseTimer;
    NSTimer *_bpmIncreaseTimer;
}

@synthesize transportButton, bpmLabel, quantumLabel, beatTimeLabel, quantumView;

- (void)viewDidLoad {
    [super viewDidLoad];
    _bpm = 120;
    _quanta = 4.;
    _audioEngine = [[AudioEngine alloc] initWithTempo:_bpm];
    ABLLinkSetSessionTempoCallback(
        _audioEngine.linkRef, onSessionTempoChanged, (__bridge void *)self);
    ABLLinkSetStartStopCallback(
         _audioEngine.linkRef, onStartStopStateChanged, (__bridge void *)self);
    _linkSettings = [ABLLinkSettingsViewController instance:_audioEngine.linkRef];
    _audioEngine.quantum = _quanta;
    [self.quantumView setQuantum:_quanta];

    _updateBeatTimeTimer = [NSTimer scheduledTimerWithTimeInterval:0.1
                                                            target:self
                                                          selector:@selector(updateBeatTime)
                                                          userInfo:nil
                                                           repeats:YES];
    [self updateUi];
    [self enableAudioEngine:YES];
}

- (BOOL)isPlaying {
    return _audioEngine.isPlaying;
}

- (ABLLinkRef)linkRef {
    return _audioEngine.linkRef;
}

- (void)enableAudioEngine:(BOOL)enable {
    if (enable) {
        [_audioEngine start];
    }
    else {
        [_audioEngine stop];
    }
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (void)updateUi {
    self.transportButton.selected = _audioEngine.isPlaying;
    self.bpmLabel.text = [NSString stringWithFormat:@"%.1f", _bpm];
    self.quantumLabel.text = [NSString stringWithFormat:@"%.0f", _quanta];
    [self.quantumView setQuantum:_quanta];
    [self.quantumView setIsPlaying:_audioEngine.isPlaying];
}

#pragma mark - UI Actions
- (IBAction)transportButtonAction:(TransportButton *)sender {
    #pragma unused(sender)
    _audioEngine.isPlaying = !_audioEngine.isPlaying;
}

- (IBAction)bpmIncreaseTouchDownAction:(UIButton *)sender {
    #pragma unused(sender)
    [self increaseBpm];
    _bpmIncreaseTimer = [NSTimer scheduledTimerWithTimeInterval:0.2
                                                         target:self
                                                       selector:@selector(increaseBpm)
                                                       userInfo:nil
                                                        repeats:YES];
}

- (IBAction)bpmIncreaseTouchUpInsideAction:(UIButton *)sender {
    #pragma unused(sender)
    [_bpmIncreaseTimer invalidate];
}
- (IBAction)bpmIncreaseTouchUpOutsideAction:(UIButton *)sender {
    #pragma unused(sender)
    [_bpmIncreaseTimer invalidate];
}

- (void)increaseBpm {
    ++_bpm;
    _audioEngine.bpm = _bpm;
}

- (IBAction)bpmDecreaseTouchDownAction:(UIButton *)sender {
    #pragma unused(sender)
    [self decreaseBpm];
    _bpmDecreaseTimer = [NSTimer scheduledTimerWithTimeInterval:0.2
                                                         target:self
                                                       selector:@selector(decreaseBpm)
                                                       userInfo:nil
                                                        repeats:YES];
}

- (IBAction)bpmDecreaseTouchUpOutsideAction:(UIButton *)sender {
    #pragma unused(sender)
   [_bpmDecreaseTimer invalidate];
}

- (IBAction)bpmDecreaseTouchUpInsideAction:(UIButton *)sender {
    #pragma unused(sender)
    [_bpmDecreaseTimer invalidate];
}

- (void)decreaseBpm {
    --_bpm;
    _audioEngine.bpm = _bpm;
}

- (IBAction)quantumIncreaseAction:(UIButton *)sender {
    #pragma unused(sender)
    ++_quanta;
    _audioEngine.quantum = _quanta;
    [self updateUi];
}

- (IBAction)quantumDecreaseAction:(UIButton *)sender {
    #pragma unused(sender)
    if (_quanta > 1) {
        --_quanta;
        _audioEngine.quantum = _quanta;
        [self updateUi];
    }
}

- (void)updateSessionTempo:(Float64)bpm {
    _bpm = bpm;
    [self updateUi];
}

- (void)updateIsTransportOn:(BOOL)on {
    #pragma unused(on)
    [self updateUi];
 }

- (IBAction)showLinkSettings:(UIButton *)sender {
    UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:_linkSettings];
    // this will present a view controller as a popover in iPad and a modal VC on iPhone
    _linkSettings.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self
                                                      action:@selector(hideLinkSettings:)];

    navController.modalPresentationStyle = UIModalPresentationPopover;

    UIPopoverPresentationController *popC = navController.popoverPresentationController;
    popC.permittedArrowDirections = UIPopoverArrowDirectionAny;
    popC.sourceRect = sender.frame;

    // we recommend using a size of 320x400 for the display in a popover
    _linkSettings.preferredContentSize = CGSizeMake(320., 400.);

    UIButton *button = (UIButton *)sender;
    popC.sourceView = button.superview;

    popC.backgroundColor = [UIColor whiteColor];
    _linkSettings.view.backgroundColor = [UIColor whiteColor];

    [self presentViewController:navController animated:YES completion:nil];
}

- (void)hideLinkSettings:(id)sender {
    #pragma unused(sender)
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)updateBeatTime {
    [self.quantumView setBeatTime:_audioEngine.beatTime];
    self.beatTimeLabel.text = [NSString stringWithFormat:@"%.1f", _audioEngine.beatTime];
}

@end
