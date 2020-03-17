//
//  CameraViewController.m
//  LLSimpleCamera
//
//  Created by Ömer Faruk Gül on 24/10/14.
//  Copyright (c) 2014 Ömer Faruk Gül. All rights reserved.
//

#import "LLSimpleCamera.h"
#import <ImageIO/CGImageProperties.h>
#import "UIImage+FixOrientation.h"
#import "LLSimpleCamera+Helper.h"

@interface LLSimpleCamera () <UIGestureRecognizerDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic ,strong) dispatch_queue_t recoredingQuene;
@property (nonatomic, assign) BOOL isRecordingSessionStarted;

@property (strong, nonatomic) UIView *preview;
@property (strong, nonatomic) AVCaptureStillImageOutput *stillImageOutput;

@property (strong, nonatomic) AVCaptureVideoPreviewLayer *captureVideoPreviewLayer;
@property (strong, nonatomic) AVCaptureSession *session;
@property (strong, nonatomic) AVCaptureDevice *videoCaptureDevice;
//@property (strong, nonatomic) AVCaptureDevice *audioCaptureDevice;
@property (nonatomic ,strong) AVCaptureDeviceInput *frontCamera;
@property (nonatomic ,strong) AVCaptureDeviceInput *backCamera;
@property (strong, nonatomic) AVCaptureDeviceInput *currentVideoInput;
@property (strong, nonatomic) AVCaptureDeviceInput *audioDeviceInput;
@property (nonatomic ,strong) AVCaptureVideoDataOutput *videoOutput;
@property (nonatomic ,strong) AVCaptureAudioDataOutput *audioOutput;

@property (nonatomic ,strong) AVAssetWriterInput *audioWriterInput;
@property (nonatomic ,strong) AVAssetWriterInput *videoWriterInput;
@property (nonatomic ,strong) AVAssetWriter *assetWriter;

@property (strong, nonatomic) UITapGestureRecognizer *tapGesture;
@property (strong, nonatomic) CALayer *focusBoxLayer;
@property (strong, nonatomic) CAAnimation *focusBoxAnimation;
//@property (strong, nonatomic) AVCaptureMovieFileOutput *movieFileOutput;
@property (strong, nonatomic) UIPinchGestureRecognizer *pinchGesture;
@property (nonatomic, assign) CGFloat beginGestureScale;
@property (nonatomic, assign) CGFloat effectiveScale;
@property (nonatomic ,strong) NSURL *recordingURL;
@property (nonatomic, copy) void (^didRecordCompletionBlock)(LLSimpleCamera *camera, NSURL *outputFileUrl, NSError *error);
@end

NSString *const LLSimpleCameraErrorDomain = @"LLSimpleCameraErrorDomain";

@implementation LLSimpleCamera

#pragma mark - Initialize

- (instancetype)init
{
    return [self initWithVideoEnabled:NO];
}

- (instancetype)initWithVideoEnabled:(BOOL)videoEnabled
{
    return [self initWithQuality:AVCaptureSessionPresetHigh position:LLCameraPositionRear videoEnabled:videoEnabled];
}

- (instancetype)initWithQuality:(NSString *)quality position:(LLCameraPosition)position videoEnabled:(BOOL)videoEnabled
{
    self = [super initWithNibName:nil bundle:nil];
    if(self) {
        [self setupWithQuality:quality position:position videoEnabled:videoEnabled];
    }
    
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder
{
    if (self = [super initWithCoder:aDecoder]) {
        [self setupWithQuality:AVCaptureSessionPresetHigh
                      position:LLCameraPositionRear
                  videoEnabled:YES];
    }
    return self;
}

- (void)setupWithQuality:(NSString *)quality
                position:(LLCameraPosition)position
            videoEnabled:(BOOL)videoEnabled
{
    _cameraQuality = quality;
    _position = position;
    _fixOrientationAfterCapture = NO;
    _tapToFocus = YES;
    _useDeviceOrientation = NO;
    _flash = LLCameraFlashOff;
    _mirror = LLCameraMirrorAuto;
    _videoEnabled = videoEnabled;
    _recording = NO;
    _zoomingEnabled = YES;
    _effectiveScale = 1.0f;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    self.view.backgroundColor = [UIColor clearColor];
    self.view.autoresizingMask = UIViewAutoresizingNone;
    
    self.preview = [[UIView alloc] initWithFrame:CGRectZero];
    self.preview.backgroundColor = [UIColor clearColor];
    [self.view addSubview:self.preview];
    
    // tap to focus
    self.tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(previewTapped:)];
    self.tapGesture.numberOfTapsRequired = 1;
    [self.tapGesture setDelaysTouchesEnded:NO];
    [self.preview addGestureRecognizer:self.tapGesture];
    
    //pinch to zoom
    if (_zoomingEnabled) {
        self.pinchGesture = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(handlePinchGesture:)];
        self.pinchGesture.delegate = self;
        [self.preview addGestureRecognizer:self.pinchGesture];
    }
    
    // add focus box to view
    [self addDefaultFocusBox];
}

#pragma mark Pinch Delegate

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer
{
    if ( [gestureRecognizer isKindOfClass:[UIPinchGestureRecognizer class]] ) {
        _beginGestureScale = _effectiveScale;
    }
    return YES;
}

- (void)handlePinchGesture:(UIPinchGestureRecognizer *)recognizer
{
    BOOL allTouchesAreOnThePreviewLayer = YES;
    NSUInteger numTouches = [recognizer numberOfTouches], i;
    for ( i = 0; i < numTouches; ++i ) {
        CGPoint location = [recognizer locationOfTouch:i inView:self.preview];
        CGPoint convertedLocation = [self.preview.layer convertPoint:location fromLayer:self.view.layer];
        if ( ! [self.preview.layer containsPoint:convertedLocation] ) {
            allTouchesAreOnThePreviewLayer = NO;
            break;
        }
    }
    
    if (allTouchesAreOnThePreviewLayer) {
        _effectiveScale = _beginGestureScale * recognizer.scale;
        if (_effectiveScale < 1.0f)
            _effectiveScale = 1.0f;
        if (_effectiveScale > self.videoCaptureDevice.activeFormat.videoMaxZoomFactor)
            _effectiveScale = self.videoCaptureDevice.activeFormat.videoMaxZoomFactor;
        NSError *error = nil;
        if ([self.videoCaptureDevice lockForConfiguration:&error]) {
            [self.videoCaptureDevice rampToVideoZoomFactor:_effectiveScale withRate:100];
            [self.videoCaptureDevice unlockForConfiguration];
        } else {
            [self passError:error];
        }
    }
}

#pragma mark - Camera

- (void)attachToViewController:(UIViewController *)vc withFrame:(CGRect)frame
{
    [vc addChildViewController:self];
    self.view.frame = frame;
    [vc.view addSubview:self.view];
    [self didMoveToParentViewController:vc];
}

- (void)start
{
    [LLSimpleCamera requestCameraPermission:^(BOOL granted) {
        if(granted) {
            // request microphone permission if video is enabled
            if(self.videoEnabled) {
                [LLSimpleCamera requestMicrophonePermission:^(BOOL granted) {
                    if(granted) {
                        [self initialize];
                    }
                    else {
                        NSError *error = [NSError errorWithDomain:LLSimpleCameraErrorDomain
                                                             code:LLSimpleCameraErrorCodeMicrophonePermission
                                                         userInfo:nil];
                        [self passError:error];
                    }
                }];
            }
            else {
                [self initialize];
            }
        }
        else {
            NSError *error = [NSError errorWithDomain:LLSimpleCameraErrorDomain
                                                 code:LLSimpleCameraErrorCodeCameraPermission
                                             userInfo:nil];
            [self passError:error];
        }
    }];
}

- (void)initialize
{
    if(!_session) {
        self.whiteBalanceMode = AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance;
        
        [self initializeCaptureDevice];
        [self initializeDeviceInput];
        [self initializeDeviceOutput];
        [self initializeSession];
        
        // preview layer
        CGRect bounds = self.preview.layer.bounds;
        _captureVideoPreviewLayer = [[AVCaptureVideoPreviewLayer alloc] initWithSession:self.session];
        _captureVideoPreviewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        _captureVideoPreviewLayer.bounds = bounds;
        _captureVideoPreviewLayer.position = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
        _captureVideoPreviewLayer.connection.videoOrientation = [self orientationForConnection];
        [self.preview.layer addSublayer:_captureVideoPreviewLayer];
    }
    
    //if we had disabled the connection on capture, re-enable it
    if (![self.captureVideoPreviewLayer.connection isEnabled]) {
        [self.captureVideoPreviewLayer.connection setEnabled:YES];
    }
    
    [self.session startRunning];
}

- (void)stop
{
    [self.session stopRunning];
}

- (void)initializeWriterInput
{
    if (!self.recordingURL) {
        return;
    }
    
    if (!self.recoredingQuene) {
        self.recoredingQuene = dispatch_queue_create("LLSimpleCamera.captureQueue", DISPATCH_QUEUE_SERIAL);
    }
    
    NSDictionary *audioSetting = @{AVFormatIDKey:@(kAudioFormatAppleIMA4),
                          AVNumberOfChannelsKey:@(1),
                          AVSampleRateKey:@(32000.0)};
    
    NSDictionary *videoSetting = @{AVVideoCodecKey:AVVideoCodecH264,
                          AVVideoWidthKey:@((NSInteger)(ceil(CGRectGetWidth(self.view.frame) / 16.0)) * 16),
                          AVVideoHeightKey:@((NSInteger)(ceil(CGRectGetHeight(self.view.frame) / 16.0)) * 16),
                          AVVideoScalingModeKey:AVVideoScalingModeResizeAspectFill};
    
    //writer input
    self.audioWriterInput = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeAudio outputSettings:audioSetting];
    self.videoWriterInput = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeVideo outputSettings:videoSetting];
    
    self.videoWriterInput.expectsMediaDataInRealTime = YES;
    self.audioWriterInput.expectsMediaDataInRealTime = YES;
    
    //asset writer
    self.assetWriter = [[AVAssetWriter alloc] initWithURL:self.recordingURL fileType:AVFileTypeQuickTimeMovie error:nil];
    
    if ([self.assetWriter canAddInput:self.videoWriterInput]) {
        [self.assetWriter addInput:self.videoWriterInput];
    }
    
    if ([self.assetWriter canAddInput:self.audioWriterInput]) {
        [self.assetWriter addInput:self.audioWriterInput];
    }
}

- (void)initializeCaptureDevice
{
    AVCaptureDevicePosition devicePosition;
    switch (self.position) {
        case LLCameraPositionRear:
            if([self.class isRearCameraAvailable]) {
                devicePosition = AVCaptureDevicePositionBack;
            } else {
                devicePosition = AVCaptureDevicePositionFront;
                _position = LLCameraPositionFront;
            }
            break;
        case LLCameraPositionFront:
            if([self.class isFrontCameraAvailable]) {
                devicePosition = AVCaptureDevicePositionFront;
            } else {
                devicePosition = AVCaptureDevicePositionBack;
                _position = LLCameraPositionRear;
            }
            break;
        default:
            devicePosition = AVCaptureDevicePositionUnspecified;
            break;
    }
    
    if (devicePosition != AVCaptureDevicePositionUnspecified) {
        NSArray *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
        for (AVCaptureDevice *device in devices) {
            if (device.position == devicePosition) {
                self.videoCaptureDevice = device;
                break;
            }
        }
    }
    if (!self.videoCaptureDevice) {
        self.videoCaptureDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    }
}

- (void)initializeDeviceOutput
{
    self.stillImageOutput = [[AVCaptureStillImageOutput alloc] init];
    [self.stillImageOutput setOutputSettings:@{AVVideoCodecKey:AVVideoCodecJPEG}];
    
    self.videoOutput = [[AVCaptureVideoDataOutput alloc] init];
    self.audioOutput = [[AVCaptureAudioDataOutput alloc] init];
}

- (void)initializeDeviceInput
{
    NSError *error = nil;
    //camera
    NSArray *cameraDevices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
    for (AVCaptureDevice *camera in cameraDevices) {
        if (camera.position == AVCaptureDevicePositionFront) {
            self.frontCamera = [[AVCaptureDeviceInput alloc] initWithDevice:camera error:nil];
        } else {
            self.backCamera = [[AVCaptureDeviceInput alloc] initWithDevice:camera error:nil];
        }
    }
    
    //audio
    AVCaptureDevice *audioDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
    self.audioDeviceInput = [[AVCaptureDeviceInput alloc] initWithDevice:audioDevice error:&error];
    [self passError:error];
    
    //default camera
    self.currentVideoInput = self.togglePosition == LLCameraPositionRear ? self.backCamera : self.frontCamera;
}

- (void)initializeSession
{
    self.session = [[AVCaptureSession alloc] init];
    
    [self.session beginConfiguration];
    
    self.session.sessionPreset = self.cameraQuality;
    
    //input
    if ([self.session canAddInput:self.currentVideoInput]) {
        [self.session addInput:self.currentVideoInput];
    }
    if ([self.session canAddInput:self.audioDeviceInput]) {
        [self.session addInput:self.audioDeviceInput];
    }
    
    //output
    if ([self.session canAddOutput:self.videoOutput]) {
        [self.session addOutput:self.videoOutput];
    }
    if ([self.session canAddOutput:self.audioOutput]) {
        [self.session addOutput:self.audioOutput];
    }
    if ([self.session canAddOutput:self.audioOutput]) {
        [self.session addOutput:self.audioOutput];
    }
    if ([self.session canAddOutput:self.stillImageOutput]) {
        [self.session addOutput:self.stillImageOutput];
    }
    
    [self updateSesionCamera];
    
    [self.session commitConfiguration];
}

- (void)updateSesionCamera
{
    for (AVCaptureConnection *videoConnection in self.videoOutput.connections) {
        if (videoConnection.isVideoStabilizationSupported) {
            //if turn on, video will missing last frames
            //see about https://stackoverflow.com/questions/56594582/avassetwriter-missing-last-frames
            videoConnection.preferredVideoStabilizationMode = AVCaptureVideoStabilizationModeOff;
        }
        if (videoConnection.isVideoOrientationSupported) {
            videoConnection.videoOrientation = AVCaptureVideoOrientationPortrait;
        }
        
        switch (self.mirror) {
            case LLCameraMirrorOff: {
                if ([videoConnection isVideoMirroringSupported]) {
                    [videoConnection setVideoMirrored:NO];
                }
                break;
            }
            case LLCameraMirrorOn: {
                if ([videoConnection isVideoMirroringSupported]) {
                    [videoConnection setVideoMirrored:YES];
                }
                break;
            }
            case LLCameraMirrorAuto: {
                BOOL shouldMirror = (_position == LLCameraPositionFront);
                if ([videoConnection isVideoMirroringSupported]) {
                    [videoConnection setVideoMirrored:shouldMirror];
                }
                break;
            }
        }
    }
}

- (void)clearTempFileIfNeeded
{
    if ([[NSFileManager defaultManager] fileExistsAtPath:self.recordingURL.path]) {
        [[NSFileManager defaultManager] removeItemAtURL:self.recordingURL error:nil];
    }
}

#pragma mark - Image Capture

-(void)capture:(void (^)(LLSimpleCamera *camera, UIImage *image, NSDictionary *metadata, NSError *error))onCapture exactSeenImage:(BOOL)exactSeenImage animationBlock:(void (^)(AVCaptureVideoPreviewLayer *))animationBlock
{
    if(!self.session) {
        NSError *error = [NSError errorWithDomain:LLSimpleCameraErrorDomain
                                    code:LLSimpleCameraErrorCodeSession
                                userInfo:nil];
        onCapture(self, nil, nil, error);
        return;
    }
    
    // get connection and set orientation
    AVCaptureConnection *videoConnection = [self captureConnection];
    videoConnection.videoOrientation = [self orientationForConnection];
    
    BOOL flashActive = self.videoCaptureDevice.flashActive;
    if (!flashActive && animationBlock) {
        animationBlock(self.captureVideoPreviewLayer);
    }
    
    [self.stillImageOutput captureStillImageAsynchronouslyFromConnection:videoConnection completionHandler: ^(CMSampleBufferRef imageSampleBuffer, NSError *error) {
        
         UIImage *image = nil;
         NSDictionary *metadata = nil;
         
         // check if we got the image buffer
         if (imageSampleBuffer != NULL) {
             CFDictionaryRef exifAttachments = CMGetAttachment(imageSampleBuffer, kCGImagePropertyExifDictionary, NULL);
             if(exifAttachments) {
                 metadata = (__bridge NSDictionary*)exifAttachments;
             }
             
             NSData *imageData = [AVCaptureStillImageOutput jpegStillImageNSDataRepresentation:imageSampleBuffer];
             image = [[UIImage alloc] initWithData:imageData];
             
             if(exactSeenImage) {
                 image = [self cropImage:image usingPreviewLayer:self.captureVideoPreviewLayer];
             }
             
             if(self.fixOrientationAfterCapture) {
                 image = [image fixOrientation];
             }
         }
         
         // trigger the block
         if(onCapture) {
             dispatch_async(dispatch_get_main_queue(), ^{
                onCapture(self, image, metadata, error);
             });
         }
     }];
}

-(void)capture:(void (^)(LLSimpleCamera *camera, UIImage *image, NSDictionary *metadata, NSError *error))onCapture exactSeenImage:(BOOL)exactSeenImage {
    
    [self capture:onCapture exactSeenImage:exactSeenImage animationBlock:^(AVCaptureVideoPreviewLayer *layer) {
        CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"opacity"];
        animation.duration = 0.1;
        animation.autoreverses = YES;
        animation.repeatCount = 0.0;
        animation.fromValue = [NSNumber numberWithFloat:1.0];
        animation.toValue = [NSNumber numberWithFloat:0.1];
        animation.fillMode = kCAFillModeForwards;
        animation.removedOnCompletion = NO;
        [layer addAnimation:animation forKey:@"animateOpacity"];
    }];
}

-(void)capture:(void (^)(LLSimpleCamera *camera, UIImage *image, NSDictionary *metadata, NSError *error))onCapture
{
    [self capture:onCapture exactSeenImage:NO];
}

#pragma mark - Video Capture

- (void)startRecordingWithOutputUrl:(NSURL *)url didRecord:(void (^)(LLSimpleCamera *camera, NSURL *outputFileUrl, NSError *error))completionBlock
{
    
    // check if video is enabled
    if (!self.videoEnabled) {
        NSError *error = [NSError errorWithDomain:LLSimpleCameraErrorDomain
                                             code:LLSimpleCameraErrorCodeVideoNotEnabled
                                         userInfo:nil];
        [self passError:error];
        return;
    }
    
    if (self.flash == LLCameraFlashOn) {
        [self enableTorch:YES];
    }
    
    self.recording = YES;
    self.recordingURL = url;
    self.didRecordCompletionBlock = completionBlock;
    [self clearTempFileIfNeeded];
    [self initializeWriterInput];
    [self.assetWriter startWriting];
    [self.videoOutput setSampleBufferDelegate:self queue:self.recoredingQuene];
    [self.audioOutput setSampleBufferDelegate:self queue:self.recoredingQuene];
    
    if (self.onStartRecording) self.onStartRecording(self);
}

- (void)stopRecording
{
    if (!self.videoEnabled) {
        return;
    }
    if (!self.isRecordingSessionStarted) {
        return;
    }
    
    [self.videoWriterInput markAsFinished];
    [self.audioWriterInput markAsFinished];
    
    __weak typeof(self) weakSelf = self;
    [self.assetWriter finishWritingWithCompletionHandler:^{
        [self.videoOutput setSampleBufferDelegate:nil queue:nil];
        [self.audioOutput setSampleBufferDelegate:nil queue:nil];
        
        weakSelf.recording = NO;
        weakSelf.isRecordingSessionStarted = NO;
        [weakSelf enableTorch:NO];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (weakSelf.didRecordCompletionBlock) {
                weakSelf.didRecordCompletionBlock(weakSelf, weakSelf.recordingURL, weakSelf.assetWriter.error);
            }
        });
    }];
}

#pragma mark - AVCaptureAudioDataOutputSampleBufferDelegate & AVCaptureVideoDataOutputSampleBufferDelegate

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection
{
    if (self.isRecordingSessionStarted == NO) {
        CMTime PTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        [self.assetWriter startSessionAtSourceTime:PTS];
        self.isRecordingSessionStarted = YES;
    }
    
    [self appendSampleBuffer:sampleBuffer];
}

- (void)appendSampleBuffer:(CMSampleBufferRef)sampleBuffer
{
    CMMediaType mediaType = CMFormatDescriptionGetMediaType(CMSampleBufferGetFormatDescription(sampleBuffer));
    switch (mediaType) {
        case kCMMediaType_Audio:
            if (self.audioWriterInput.isReadyForMoreMediaData) {
                [self.audioWriterInput appendSampleBuffer:sampleBuffer];
            }
            break;
        default:
            if (self.videoWriterInput.isReadyForMoreMediaData) {
                [self.videoWriterInput appendSampleBuffer:sampleBuffer];
            }
            break;
    }
}

- (void)enableTorch:(BOOL)enabled
{
    // check if the device has a torch, otherwise don't do anything
    if([self isTorchAvailable]) {
        AVCaptureTorchMode torchMode = enabled ? AVCaptureTorchModeOn : AVCaptureTorchModeOff;
        NSError *error;
        if ([self.videoCaptureDevice lockForConfiguration:&error]) {
            [self.videoCaptureDevice setTorchMode:torchMode];
            [self.videoCaptureDevice unlockForConfiguration];
        } else {
            [self passError:error];
        }
    }
}

#pragma mark - Helpers

- (void)passError:(NSError *)error
{
    if (error && self.onError) {
        __weak typeof(self) weakSelf = self;
        self.onError(weakSelf, error);
    }
}

- (AVCaptureConnection *)captureConnection
{
    AVCaptureConnection *videoConnection = nil;
    for (AVCaptureConnection *connection in self.stillImageOutput.connections) {
        for (AVCaptureInputPort *port in [connection inputPorts]) {
            if ([[port mediaType] isEqual:AVMediaTypeVideo]) {
                videoConnection = connection;
                break;
            }
        }
        if (videoConnection) {
            break;
        }
    }
    
    return videoConnection;
}

- (void)setVideoCaptureDevice:(AVCaptureDevice *)videoCaptureDevice
{
    _videoCaptureDevice = videoCaptureDevice;
    
    if(videoCaptureDevice.flashMode == AVCaptureFlashModeAuto) {
        _flash = LLCameraFlashAuto;
    } else if(videoCaptureDevice.flashMode == AVCaptureFlashModeOn) {
        _flash = LLCameraFlashOn;
    } else if(videoCaptureDevice.flashMode == AVCaptureFlashModeOff) {
        _flash = LLCameraFlashOff;
    } else {
        _flash = LLCameraFlashOff;
    }
    
    _effectiveScale = 1.0f;
    
    // trigger block
    if(self.onDeviceChange) {
        __weak typeof(self) weakSelf = self;
        self.onDeviceChange(weakSelf, videoCaptureDevice);
    }
}

- (BOOL)isFlashAvailable
{
    return self.videoCaptureDevice.hasFlash && self.videoCaptureDevice.isFlashAvailable;
}

- (BOOL)isTorchAvailable
{
    return self.videoCaptureDevice.hasTorch && self.videoCaptureDevice.isTorchAvailable;
}

- (BOOL)updateFlashMode:(LLCameraFlash)cameraFlash
{
    if(!self.session)
        return NO;
    
    AVCaptureFlashMode flashMode;
    
    if(cameraFlash == LLCameraFlashOn) {
        flashMode = AVCaptureFlashModeOn;
    } else if(cameraFlash == LLCameraFlashAuto) {
        flashMode = AVCaptureFlashModeAuto;
    } else {
        flashMode = AVCaptureFlashModeOff;
    }
    
    if([self.videoCaptureDevice isFlashModeSupported:flashMode]) {
        NSError *error;
        if([self.videoCaptureDevice lockForConfiguration:&error]) {
            self.videoCaptureDevice.flashMode = flashMode;
            [self.videoCaptureDevice unlockForConfiguration];
            
            _flash = cameraFlash;
            return YES;
        } else {
            [self passError:error];
            return NO;
        }
    }
    else {
        return NO;
    }
}

- (void)setWhiteBalanceMode:(AVCaptureWhiteBalanceMode)whiteBalanceMode
{
    if ([self.videoCaptureDevice isWhiteBalanceModeSupported:whiteBalanceMode]) {
        NSError *error;
        if ([self.videoCaptureDevice lockForConfiguration:&error]) {
            [self.videoCaptureDevice setWhiteBalanceMode:whiteBalanceMode];
            [self.videoCaptureDevice unlockForConfiguration];
        } else {
            [self passError:error];
        }
    }
}

- (void)setMirror:(LLCameraMirror)mirror
{
    _mirror = mirror;

    if(!self.session) {
        return;
    }
    
    [self.session beginConfiguration];
    [self updateSesionCamera];
    [self.session commitConfiguration];
}

- (LLCameraPosition)togglePosition
{
    if(!self.session) {
        return self.position;
    }
    
    if(self.position == LLCameraPositionRear) {
        self.cameraPosition = LLCameraPositionFront;
    } else {
        self.cameraPosition = LLCameraPositionRear;
    }
    
    return self.position;
}

- (void)setCameraPosition:(LLCameraPosition)cameraPosition
{
    if(_position == cameraPosition || !self.session) {
        return;
    }
    
    if(cameraPosition == LLCameraPositionRear && ![self.class isRearCameraAvailable]) {
        return;
    }
    
    if(cameraPosition == LLCameraPositionFront && ![self.class isFrontCameraAvailable]) {
        return;
    }
    
    _position = cameraPosition;
    
    [self.session beginConfiguration];
    // remove existing input
    [self.session removeInput:self.currentVideoInput];
    // get new input
    if(self.currentVideoInput.device.position == AVCaptureDevicePositionBack) {
        self.currentVideoInput = self.frontCamera;
    } else {
        self.currentVideoInput = self.backCamera;
    }
    // add input to session
    [self.session addInput:self.currentVideoInput];
    [self updateSesionCamera];
    [self.session commitConfiguration];
}

#pragma mark - Focus

- (void)previewTapped:(UIGestureRecognizer *)gestureRecognizer
{
    if(!self.tapToFocus) {
        return;
    }
    
    CGPoint touchedPoint = [gestureRecognizer locationInView:self.preview];
    CGPoint pointOfInterest = [self convertToPointOfInterestFromViewCoordinates:touchedPoint
                                                                   previewLayer:self.captureVideoPreviewLayer
                                                                          ports:self.currentVideoInput.ports];
    [self focusAtPoint:pointOfInterest];
    [self showFocusBox:touchedPoint];
}

- (void)addDefaultFocusBox
{
    CALayer *focusBox = [[CALayer alloc] init];
    focusBox.cornerRadius = 5.0f;
    focusBox.bounds = CGRectMake(0.0f, 0.0f, 70, 60);
    focusBox.borderWidth = 3.0f;
    focusBox.borderColor = [[UIColor yellowColor] CGColor];
    focusBox.opacity = 0.0f;
    [self.view.layer addSublayer:focusBox];
    
    CABasicAnimation *focusBoxAnimation = [CABasicAnimation animationWithKeyPath:@"opacity"];
    focusBoxAnimation.duration = 0.75;
    focusBoxAnimation.autoreverses = NO;
    focusBoxAnimation.repeatCount = 0.0;
    focusBoxAnimation.fromValue = [NSNumber numberWithFloat:1.0];
    focusBoxAnimation.toValue = [NSNumber numberWithFloat:0.0];
    
    [self alterFocusBox:focusBox animation:focusBoxAnimation];
}

- (void)alterFocusBox:(CALayer *)layer animation:(CAAnimation *)animation
{
    self.focusBoxLayer = layer;
    self.focusBoxAnimation = animation;
}

- (void)focusAtPoint:(CGPoint)point
{
    AVCaptureDevice *device = self.videoCaptureDevice;
    if (device.isFocusPointOfInterestSupported && [device isFocusModeSupported:AVCaptureFocusModeAutoFocus]) {
        NSError *error;
        if ([device lockForConfiguration:&error]) {
            device.focusPointOfInterest = point;
            device.focusMode = AVCaptureFocusModeAutoFocus;
            [device unlockForConfiguration];
        } else {
            [self passError:error];
        }
    }
}

- (void)showFocusBox:(CGPoint)point
{
    if(self.focusBoxLayer) {
        // clear animations
        [self.focusBoxLayer removeAllAnimations];
        
        // move layer to the touch point
        [CATransaction begin];
        [CATransaction setValue: (id) kCFBooleanTrue forKey: kCATransactionDisableActions];
        self.focusBoxLayer.position = point;
        [CATransaction commit];
    }
    
    if(self.focusBoxAnimation) {
        // run the animation
        [self.focusBoxLayer addAnimation:self.focusBoxAnimation forKey:@"animateOpacity"];
    }
}

#pragma mark - UIViewController

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
}

- (void)viewWillLayoutSubviews
{
    [super viewWillLayoutSubviews];
    
    self.preview.frame = CGRectMake(0, 0, self.view.bounds.size.width, self.view.bounds.size.height);
    
    CGRect bounds = self.preview.bounds;
    self.captureVideoPreviewLayer.bounds = bounds;
    self.captureVideoPreviewLayer.position = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
    
    self.captureVideoPreviewLayer.connection.videoOrientation = [self orientationForConnection];
}

- (AVCaptureVideoOrientation)orientationForConnection
{
    AVCaptureVideoOrientation videoOrientation = AVCaptureVideoOrientationPortrait;
    
    if(self.useDeviceOrientation) {
        switch ([UIDevice currentDevice].orientation) {
            case UIDeviceOrientationLandscapeLeft:
                // yes to the right, this is not bug!
                videoOrientation = AVCaptureVideoOrientationLandscapeRight;
                break;
            case UIDeviceOrientationLandscapeRight:
                videoOrientation = AVCaptureVideoOrientationLandscapeLeft;
                break;
            case UIDeviceOrientationPortraitUpsideDown:
                videoOrientation = AVCaptureVideoOrientationPortraitUpsideDown;
                break;
            default:
                videoOrientation = AVCaptureVideoOrientationPortrait;
                break;
        }
    }
    else {
        switch ([[UIApplication sharedApplication] statusBarOrientation]) {
            case UIInterfaceOrientationLandscapeLeft:
                videoOrientation = AVCaptureVideoOrientationLandscapeLeft;
                break;
            case UIInterfaceOrientationLandscapeRight:
                videoOrientation = AVCaptureVideoOrientationLandscapeRight;
                break;
            case UIInterfaceOrientationPortraitUpsideDown:
                videoOrientation = AVCaptureVideoOrientationPortraitUpsideDown;
                break;
            default:
                videoOrientation = AVCaptureVideoOrientationPortrait;
                break;
        }
    }
    
    return videoOrientation;
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator
{
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    
    // layout subviews is not called when rotating from landscape right/left to left/right ?
    [self.view setNeedsLayout];
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
}

- (void)dealloc {
    [self stop];
}

#pragma mark - Class Methods

+ (void)requestCameraPermission:(void (^)(BOOL granted))completionBlock
{
    if ([AVCaptureDevice respondsToSelector:@selector(requestAccessForMediaType: completionHandler:)]) {
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
            // return to main thread
            dispatch_async(dispatch_get_main_queue(), ^{
                if(completionBlock) {
                    completionBlock(granted);
                }
            });
        }];
    } else {
        completionBlock(YES);
    }
}

+ (void)requestMicrophonePermission:(void (^)(BOOL granted))completionBlock
{
    if([[AVAudioSession sharedInstance] respondsToSelector:@selector(requestRecordPermission:)]) {
        [[AVAudioSession sharedInstance] requestRecordPermission:^(BOOL granted) {
            // return to main thread
            dispatch_async(dispatch_get_main_queue(), ^{
                if(completionBlock) {
                    completionBlock(granted);
                }
            });
        }];
    }
}

+ (BOOL)isFrontCameraAvailable
{
    return [UIImagePickerController isCameraDeviceAvailable:UIImagePickerControllerCameraDeviceFront];
}

+ (BOOL)isRearCameraAvailable
{
    return [UIImagePickerController isCameraDeviceAvailable:UIImagePickerControllerCameraDeviceRear];
}

@end
