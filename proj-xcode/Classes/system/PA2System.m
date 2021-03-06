/**
 * Copyright 2016 Lime - HighTech Solutions s.r.o.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "PA2System.h"
#import "PA2Session.h"
#import <UIKit/UIKit.h>

BOOL pa_isJailbroken() {
#if !(TARGET_IPHONE_SIMULATOR)
	
	if ([[NSFileManager defaultManager] fileExistsAtPath:@"/Applications/Cydia.app"]
		|| [[NSFileManager defaultManager] fileExistsAtPath:@"/Library/MobileSubstrate/MobileSubstrate.dylib"]
		|| [[NSFileManager defaultManager] fileExistsAtPath:@"/bin/bash"]
		|| [[NSFileManager defaultManager] fileExistsAtPath:@"/usr/sbin/sshd"]
		|| [[NSFileManager defaultManager] fileExistsAtPath:@"/etc/apt"]
		|| [[NSFileManager defaultManager] fileExistsAtPath:@"/private/var/lib/apt/"]
		|| [[UIApplication sharedApplication] canOpenURL:[NSURL URLWithString:@"cydia://package/com.example.package"]])  {
		return YES;
	}
	
	FILE *f = NULL ;
	if ((f = fopen("/bin/bash", "r"))
		|| (f = fopen("/Applications/Cydia.app", "r"))
		|| (f = fopen("/Library/MobileSubstrate/MobileSubstrate.dylib", "r"))
		|| (f = fopen("/usr/sbin/sshd", "r"))
		|| (f = fopen("/etc/apt", "r")))  {
		fclose(f);
		return YES;
	}
	fclose(f);
	
	NSError *error;
	NSString *stringToBeWritten = @"This is a test.";
	[stringToBeWritten writeToFile:@"/private/jailbreak.txt" atomically:YES encoding:NSUTF8StringEncoding error:&error];
	[[NSFileManager defaultManager] removeItemAtPath:@"/private/jailbreak.txt" error:nil];
	if(error == nil) {
		return YES;
	}
	
#endif
	
	return NO;
}

@implementation PA2System

+ (BOOL) isInDebug {
	return [PA2Session hasDebugFeatures];
}

+ (BOOL) isJailbroken {
	return pa_isJailbroken();
}

@end
