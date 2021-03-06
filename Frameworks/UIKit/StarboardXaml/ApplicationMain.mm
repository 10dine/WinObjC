﻿//******************************************************************************
//
// Copyright (c) Microsoft. All rights reserved.
//
// This code is licensed under the MIT License (MIT).
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
//
//******************************************************************************

#import <UIKit/UIWindow.h>

#include <COMIncludes.h>
#import "ApplicationMain.h"
#import <windows.foundation.h>
#import <windows.applicationmodel.activation.h>
#include <COMIncludes_End.h>

#import <assert.h>
#import <math.h>
#import <malloc.h>
#import <string>

#import <vector>
#import <algorithm>

#import <d3d11.h>
#import <d3d11_2.h>

#import <Starboard.h>
#import <StringHelpers.h>
#import <CollectionHelpers.h>
#import <UIInterface.h>
#import <CACompositorClient.h>
#import <UIApplicationInternal.h>
#import <MainDispatcher.h>
#import <_UIPopupViewController.h>
#import <UWP/WindowsApplicationModelActivation.h>
#import <UWP/WindowsUIXamlControlsPrimitives.h>

using namespace Microsoft::WRL;

static CACompositorClientInterface* _compositorClient = NULL;

void SetCACompositorClient(CACompositorClientInterface* client) {
    _compositorClient = client;
}

int ApplicationMainStart(const char* principalName,
                         const char* delegateName,
                         float windowWidth,
                         float windowHeight,
                         ActivationType activationType,
                         IInspectable* activationArg) {
    // Note: We must use nil rather than an empty string for these class names
    NSString* principalClassName = Strings::IsEmpty<const char*>(principalName) ? nil : [[NSString alloc] initWithCString:principalName];
    NSString* delegateClassName = Strings::IsEmpty<const char*>(delegateName) ? nil : [[NSString alloc] initWithCString:delegateName];

    id activationArgument = nil;

    // Populate Objective C equivalent of activation argument
    if (activationType == ActivationTypeToast) {
        WAAToastNotificationActivatedEventArgs* toastArgument = [WAAToastNotificationActivatedEventArgs createWith:activationArg];

        // Convert to NSDictionary with NSStrings
        ComPtr<IInspectable> comPtr = activationArg;
        ComPtr<ABI::Windows::ApplicationModel::Activation::IToastNotificationActivatedEventArgs> args;
        THROW_NS_IF_FAILED(comPtr.As(&args));

        ComPtr<ABI::Windows::Foundation::Collections::IPropertySet> map;
        THROW_NS_IF_FAILED(args->get_UserInput(&map));

        NSMutableDictionary* userInput = nil;
        THROW_NS_IF_FAILED(Collections::WRLToNSCollection(map, &userInput));

        NSDictionary* toastAction = @{
            UIApplicationLaunchOptionsToastActionArgumentKey : toastArgument.argument,
            UIApplicationLaunchOptionsToastActionUserInputKey : userInput
        };
        activationArgument = toastAction;
    } else if (activationType == ActivationTypeVoiceCommand) {
        WMSSpeechRecognitionResult* result = [WMSSpeechRecognitionResult createWith:(IInspectable*)activationArg];
        activationArgument = result;
    } else if (activationType == ActivationTypeProtocol) {
        WFUri* uri = [WFUri createWith:(IInspectable*)activationArg];
        activationArgument = uri;
    } else if (activationType == ActivationTypeFile) {
        WAAFileActivatedEventArgs* activatedEventArgs = [WAAFileActivatedEventArgs createWith:activationArg];
        activationArgument = activatedEventArgs;
    }

    WOCDisplayMode* displayMode = [UIApplication displayMode];
    [displayMode _setWindowSize:CGSizeMake(windowWidth, windowHeight)];

    if (activationType == ActivationTypeLibrary) {
        // In library mode, honor app's native display size
        [displayMode setDisplayPreset:WOCDisplayPresetNative];
    }

    NSDictionary* infoDict = [[NSBundle mainBundle] infoDictionary];

    //  Figure out what our initial default orientation should be from Info.plist
    UIInterfaceOrientation defaultOrientation = UIInterfaceOrientationUnknown;
    if (infoDict != nil) {
        defaultOrientation = EbrGetWantedOrientation();

        id orientation = [infoDict objectForKey:@"UISupportedInterfaceOrientations"];

        if (orientation == nil) {
            orientation = [infoDict objectForKey:@"UIInterfaceOrientation"];
        }

        if ([orientation isKindOfClass:[NSString class]]) {
            defaultOrientation = UIOrientationFromString(defaultOrientation, (NSString*)orientation);
        } else if ([orientation isKindOfClass:[NSArray class]]) {
            bool found = false;

            for (NSString* curstr in orientation) {
                UIInterfaceOrientation newOrientation = UIOrientationFromString(defaultOrientation, curstr);
                if (newOrientation == defaultOrientation) {
                    found = true;
                    break;
                }
            }

            if (!found) {
                if ([(NSArray*)orientation count] > 0) {
                    defaultOrientation = UIOrientationFromString(defaultOrientation, [(NSArray*)orientation objectAtIndex:0]);
                } else {
                    defaultOrientation = UIInterfaceOrientationPortrait;
                }
            }
        } else {
            defaultOrientation = UIInterfaceOrientationPortrait;
        }
    }

//  Setup default landscape presentation transform on desktop only,
//  based on the declared default application orientations
#if WINAPI_FAMILY != WINAPI_FAMILY_PHONE_APP
    if (defaultOrientation == UIInterfaceOrientationLandscapeLeft || defaultOrientation == UIInterfaceOrientationLandscapeRight) {
        displayMode.presentationTransform = defaultOrientation;
    }
#endif

    if ([UIApplication respondsToSelector:@selector(setStartupDisplayMode:)]) {
        [UIApplication setStartupDisplayMode:displayMode];
    }

    [displayMode _updateDisplaySettings];

    UIApplicationMainInit(principalClassName, delegateClassName, defaultOrientation, (int)activationType, activationArgument);

    if (activationType == ActivationTypeLibrary) {
        // Create a top-level UIWindow with popup view controller, which will not normally be visible.
        // If some other view controller tries to present to it, the popup view controller will make
        // the desired UI visible inside a XAML Popup.
        WFRect* appFrame = [[WXWindow current] bounds];
        CGRect windowFrame = CGRectMake(0, 0, appFrame.width, appFrame.height);

        UIWindow* keyWindow = [[UIWindow alloc] initWithFrame:windowFrame];
        keyWindow.rootViewController = [[_UIPopupViewController alloc] init];
        [keyWindow makeKeyWindow];
    }

    // The main runloop has to be started asynchronously, so we return as soon as possible from application activate.
    // The apps can (and do) handle application launch delegate from the first tine NSRunloop run is called, and that can
    // take a REALLY long time to complete, causing PLM to terminate us.  We were getting lucky in some cases and the app would launch.
    // This will also fix the number of sporadic launch test failures that we have seen in the labs.

    ScheduleMainRunLoopAsync();

    return 0;
}

void SetTemporaryFolder(const wchar_t* folder) {
    NSSetTemporaryDirectory([NSString stringWithCharacters:reinterpret_cast<const unichar*>(folder) length:wcslen(folder)]);
}
