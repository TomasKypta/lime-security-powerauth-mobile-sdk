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

#import "PowerAuthSDK.h"

#pragma mark - Constants

/** In case a config is missing, exception with this identifier is thrown. */
NSString *const PA2ExceptionMissingConfig		= @"PA2ExceptionMissingConfig";

#pragma mark - Static variable for the configurable singleton

static PowerAuthSDK *inst;

#pragma mark - PowerAuth SDK implementation

@implementation PowerAuthSDK {
	PowerAuthConfiguration *_configuration;
	PA2Client *_client;
	NSString *_biometryKeyIdentifier;
	PA2Keychain *_statusKeychain;
	PA2Keychain *_sharedKeychain;
	PA2Keychain *_biometryOnlyKeychain;
}

#pragma mark - Private methods

- (void) initializeWithConfiguration:(PowerAuthConfiguration*)configuration {
	
	// Check if the configuration was nil
	if (configuration == nil) {
		[PowerAuthSDK throwInvalidConfigurationException];
	}
	
	// Validate that the configuration was set up correctly
	if (![configuration validateConfiguration]) {
		[PowerAuthSDK throwInvalidConfigurationException];
	}
	_configuration = configuration;
	
	// Prepare identifier for biometry related keys - use instanceId by default, or a custom value if set
	_biometryKeyIdentifier = _configuration.keychainKey_Biometry ? _configuration.keychainKey_Biometry : _configuration.instanceId;
	
	// Create session setup parameters
	PA2SessionSetup *setup = [[PA2SessionSetup alloc] init];
	setup.applicationKey = configuration.appKey;
	setup.applicationSecret = configuration.appSecret;
	setup.masterServerPublicKey = configuration.masterServerPublicKey;
	setup.externalEncryptionKey = configuration.externalEncryptionKey;
	
	// Create a new session
	_session = [[PA2Session alloc] initWithSessionSetup:setup];
	if (_session == nil) {
		[PowerAuthSDK throwInvalidConfigurationException];
	}
	
	// Create and setup a new client
	_client = [[PA2Client alloc] init];
	_client.baseEndpointUrl = configuration.baseEndpointUrl;
	_client.defaultRequestTimeout = [PA2ClientConfiguration sharedInstance].defaultRequestTimeout;
	_client.sslValidationStrategy = [PA2ClientConfiguration sharedInstance].sslValidationStrategy;
	
	// Create a new keychain instances
	PA2KeychainConfiguration *keychainConfiguration = [PA2KeychainConfiguration sharedInstance];
	_statusKeychain			= [[PA2Keychain alloc] initWithIdentifier:keychainConfiguration.keychainInstanceName_Status
													accessGroup:keychainConfiguration.keychainAttribute_AccessGroup];
	_sharedKeychain			= [[PA2Keychain alloc] initWithIdentifier:keychainConfiguration.keychainInstanceName_Possession
													accessGroup:keychainConfiguration.keychainAttribute_AccessGroup];
	_biometryOnlyKeychain	= [[PA2Keychain alloc] initWithIdentifier:keychainConfiguration.keychainInstanceName_Biometry];
	
	// Make sure to reset keychain data after app re-install.
	// Important: This deletes all Keychain data in all PowerAuthSDK instances!
	// By default, the code uses standard user defaults, use `PA2KeychainConfiguration.keychainAttribute_UserDefaultsSuiteName` to use `NSUserDefaults` with a custom suite name.
	NSUserDefaults *userDefaults = nil;
	if (keychainConfiguration.keychainAttribute_UserDefaultsSuiteName != nil) {
		userDefaults = [[NSUserDefaults alloc] initWithSuiteName:keychainConfiguration.keychainAttribute_UserDefaultsSuiteName];
	} else {
		userDefaults = [NSUserDefaults standardUserDefaults];
	}
	if ([userDefaults boolForKey:PA2Keychain_Initialized] == NO) {
		[_statusKeychain deleteAllData];
		[_sharedKeychain deleteAllData];
		[_biometryOnlyKeychain deleteAllData];
		[userDefaults setBool:YES forKey:PA2Keychain_Initialized];
		[userDefaults synchronize];
	}
	
	// Initialize encryptor factory
	_encryptorFactory = [[PA2EncryptorFactory alloc] initWithSession:_session];
	
	// Attempt to restore session state
	[self restoreState];
	
}

+ (void) throwInvalidConfigurationException {
	[NSException raise:PA2ExceptionMissingConfig
				format:@"Invalid PowerAuthSDK configuration. You must set a valid PowerAuthConfiguration to PowerAuthSDK instance using initializer."];
}

- (PA2ActivationStep1Param*) paramStep1WithActivationCode:(NSString*)activationCode {
	
	PA2Otp *otp = [PA2OtpUtil parseFromActivationCode:activationCode];
	if (otp == nil) {
		return nil;
	}
	
	// Prepare result and return
	PA2ActivationStep1Param *result = [[PA2ActivationStep1Param alloc] init];
	result.activationIdShort = otp.activationIdShort;
	result.activationOtp = otp.activationOtp;
	result.activationSignature = otp.activationSignature;
	
	return result;
}

#pragma mark - Key management

- (NSData*) deviceRelatedKey {
	// Cache the possession key in the keychain
	PA2KeychainConfiguration *keychainConfiguration = [PA2KeychainConfiguration sharedInstance];
	if ([_sharedKeychain containsDataForKey:keychainConfiguration.keychainKey_Possession]) {
		return [_sharedKeychain dataForKey:keychainConfiguration.keychainKey_Possession status:nil];
	} else {
		NSString *uuidString;
#if TARGET_IPHONE_SIMULATOR
		uuidString = @"ffa184f9-341a-444f-8495-de04d0d490be";
#else
		uuidString = [UIDevice currentDevice].identifierForVendor.UUIDString;
#endif
		NSData *uuidData = [uuidString dataUsingEncoding:NSUTF8StringEncoding];
		NSData *possessionKey = [PA2Session normalizeSignatureUnlockKeyFromData:uuidData];
		[_sharedKeychain addValue:possessionKey forKey:keychainConfiguration.keychainKey_Possession];
		return possessionKey;
	}
}

- (NSData*) biometryRelatedKeyUserCancelled:(nullable BOOL *)userCancelled prompt:(NSString*)prompt {
	if ([_biometryOnlyKeychain containsDataForKey:_biometryKeyIdentifier]) {
		OSStatus status;
		NSData *key = [_biometryOnlyKeychain dataForKey:_biometryKeyIdentifier status:&status prompt:prompt];
		if (userCancelled != NULL) {
			if (status == errSecUserCanceled) {
				*userCancelled = YES;
			} else {
				*userCancelled = NO;
			}
		}
		return key;
	} else {
		return nil;
	}
}

- (PA2SignatureUnlockKeys*) signatureKeysForAuthentication:(PowerAuthAuthentication*)authentication
											 userCancelled:(nullable BOOL *)userCancelled {
	
	// Generate signature key encryption keys
	NSData *possessionKey = nil;
	NSData *biometryKey = nil;
	PA2Password *knowledgeKey = nil;
	if (authentication.usePossession) {
		if (authentication.overridenPossessionKey) {
			possessionKey = authentication.overridenPossessionKey;
		} else {
			possessionKey = [self deviceRelatedKey];
		}
	}
	if (authentication.useBiometry) {
		if (authentication.overridenBiometryKey) { // user specified a custom biometry key
			biometryKey = authentication.overridenBiometryKey;
		} else { // default biometry key should be fetched
			biometryKey = [self biometryRelatedKeyUserCancelled:userCancelled prompt:authentication.touchIdPrompt];
			if (*userCancelled) {
				return nil;
			}
			// If the key was not fetched (and not because of user cancel action) and biometry
			// was requested, generate a "fake key" so that signature can silently fail
			else {
				if (biometryKey == nil) {
					PALog(@"ERROR! You are attempting Touch ID authentication despite the fact related key value is not present in the Keychain. We have generated an ad-hoc random key and your authentication will fail. Use PowerAuthSDK:hasBiometryFactor method to check the status of this key and disable Touch ID if the method returns NO / false value.");
					biometryKey = [PA2Session generateSignatureUnlockKey];
				}
			}
		}
	}
	if (authentication.usePassword) {
		knowledgeKey = [PA2Password passwordWithString:authentication.usePassword];
	}
	
	// Prepare signature unlock keys structure
	PA2SignatureUnlockKeys *keys = [[PA2SignatureUnlockKeys alloc] init];
	keys.possessionUnlockKey = possessionKey;
	keys.biometryUnlockKey = biometryKey;
	keys.userPassword = knowledgeKey;
	return keys;
}

- (PA2SignatureFactor) determineSignatureFactorForAuthentication:(PowerAuthAuthentication*)authentication {
	if (authentication.usePossession  && !authentication.usePassword && !authentication.useBiometry) {
		return PA2SignatureFactor_Possession;
	}
	if (!authentication.usePossession && authentication.usePassword  && !authentication.useBiometry) {
		return PA2SignatureFactor_Knowledge;
	}
	if (!authentication.usePossession && !authentication.usePassword && authentication.useBiometry) {
		return PA2SignatureFactor_Biometry;
	}
	if (authentication.usePossession  &&  authentication.usePassword && !authentication.useBiometry) {
		return PA2SignatureFactor_Possession_Knowledge;
	}
	if (authentication.usePossession  && !authentication.usePassword &&  authentication.useBiometry) {
		return PA2SignatureFactor_Possession_Biometry;
	}
	if (authentication.usePossession  &&  authentication.usePassword && authentication.useBiometry) {
		return PA2SignatureFactor_Possession_Knowledge_Biometry;
	}
	// In case invalid combination was selected (no factors, knowledge & biometry), expect the worst...
	return PA2SignatureFactor_Possession_Knowledge_Biometry;
}

- (PA2SignatureFactor) determineSignatureFactorForAuthentication:(PowerAuthAuthentication*)authentication
												 withVaultUnlock:(BOOL)vaultUnlock {
	if (vaultUnlock) {
		return [self determineSignatureFactorForAuthentication:authentication] + PA2SignatureFactor_PrepareForVaultUnlock;
	} else {
		return [self determineSignatureFactorForAuthentication:authentication];
	}
}

- (PA2OperationTask*) fetchEncryptedVaultUnlockKey:(PowerAuthAuthentication*)authentication
										 callback:(void(^)(NSString * encryptedEncryptionKey, NSError *error))callback {
	
	PA2OperationTask *task = [[PA2OperationTask alloc] init];
	
	// Check for the session setup
	if (!_session.hasValidSetup) {
		[PowerAuthSDK throwInvalidConfigurationException];
	}
	
	// Check if there is an activation present
	if (!_session.hasValidActivation && _session.hasPendingActivation) {
		NSError *error = [NSError errorWithDomain:PA2ErrorDomain
											 code:PA2ErrorCodeMissingActivation
										 userInfo:nil];
		callback(nil, error);
		[task cancel];
		return task;
	}
	
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		
		// Compute authorization header based on constants from the specification.
		NSError *error = nil;
		PA2AuthorizationHttpHeader *httpHeader = [self requestSignatureWithAuthentication:authentication
																			  vaultUnlock:YES
																				   method:@"POST"
																					uriId:@"/pa/vault/unlock"
																					 body:nil
																					error:&error];
		if (error) {
			callback(nil, error);
			return;
		}
		if (task.isCancelled) {
			NSError *error = [NSError errorWithDomain:PA2ErrorDomain code:PA2ErrorCodeOperationCancelled userInfo:nil];
			callback(nil, error);
			return;
		}
		
		// Perform the server request
		NSURLSessionDataTask *dataTask = [_client vaultUnlockSignatureHeader:httpHeader callback:^(PA2RestResponseStatus status, PA2VaultUnlockResponse *response, NSError *clientError) {
			// Network communication completed correctly
			if (status == PA2RestResponseStatus_OK) {
				callback(response.encryptedVaultEncryptionKey, nil);
			} else { // Network error occurred
				callback(nil, clientError);
			}
		}];
		task.dataTask = dataTask;
	});
	
	return task;
}

#pragma mark - Public methods

#pragma mark Initializers and SDK instance getters

- (instancetype)initWithConfiguration:(PowerAuthConfiguration *)configuration {
	self = [super init];
	if (self) {
		[self initializeWithConfiguration:configuration];
	}
	return self;
}

+ (void) initSharedInstance:(PowerAuthConfiguration*)configuration {
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		inst = [[PowerAuthSDK alloc] initWithConfiguration:configuration];
	});
}

+ (PowerAuthSDK*) sharedInstance {
	if (!inst) {
		[PowerAuthSDK throwInvalidConfigurationException];
	}
	return inst;
}

#pragma mark Session state management

- (BOOL) restoreState {
	NSData *sessionData = [_statusKeychain dataForKey:_configuration.instanceId status:nil];
	if (sessionData) {
		[_session resetSession];
		BOOL result = [_session deserializeState:sessionData];
		if (!result) {
			PALog(@"Unable to deserialize session state due to an unknown error.");
		}
		return result;
	} else {
		return NO;
	}
}

- (BOOL) hasPendingActivation {
	
	// Check for the session setup
	if (!_session.hasValidSetup) {
		[PowerAuthSDK throwInvalidConfigurationException];
	}
	return _session.hasPendingActivation;
}

- (BOOL) hasValidActivation {
	
	// Check for the session setup
	if (!_session.hasValidSetup) {
		[PowerAuthSDK throwInvalidConfigurationException];
	}
	return _session.hasValidActivation;
}

- (BOOL) clearActivationDataKeychain {
	BOOL deleted = true;
	deleted = deleted && [_statusKeychain deleteDataForKey:_configuration.instanceId];
	deleted = deleted && [_biometryOnlyKeychain deleteDataForKey:_biometryKeyIdentifier];
	[_session resetSession];
	return deleted;
}

- (void) reset {
	// Check for the session setup
	if (!_session.hasValidSetup) {
		[PowerAuthSDK throwInvalidConfigurationException];
	}
	[_session resetSession];
}

#pragma mark Creating a new activation

- (PA2OperationTask*) createActivationWithName:(NSString*)name
								activationCode:(NSString*)activationCode
									  callback:(void(^)(NSString *activationFingerprint, NSError *error))callback {
	return [self createActivationWithName:name activationCode:activationCode extras:nil callback:callback];
}

- (PA2OperationTask*) createActivationWithName:(NSString*)name
								activationCode:(NSString*)activationCode
										extras:(NSString*)extras
									  callback:(void(^)(NSString *activationFingerprint, NSError *error))callback {
	
	PA2OperationTask *task = [[PA2OperationTask alloc] init];
	
	// Check for the session setup
	if (!_session.hasValidSetup) {
		[PowerAuthSDK throwInvalidConfigurationException];
	}
	
	// Check if activation may be started
	if (_session.hasPendingActivation) {
		NSError *error = [NSError errorWithDomain:PA2ErrorDomain code:PA2ErrorCodeInvalidActivationState userInfo:nil];
		callback(nil, error);
		[task cancel];
		return task;
	}
	
	[_session resetSession];
	
	// Prepare crypto module request
	PA2ActivationStep1Param *paramStep1 = [self paramStep1WithActivationCode:activationCode];
	
	// Obtain crypto module response
	PA2ActivationStep1Result *resultStep1 = [_session startActivation:paramStep1];
	
	// Perform exchange over PowerAuth 2.0 Standard RESTful API
	PA2CreateActivationRequest *request = [[PA2CreateActivationRequest alloc] init];
	request.activationIdShort = paramStep1.activationIdShort;
	request.activationName = name;
	request.activationNonce = resultStep1.activationNonce;
	request.applicationKey = _configuration.appKey;
	request.applicationSignature = resultStep1.applicationSignature;
	request.encryptedDevicePublicKey = resultStep1.cDevicePublicKey;
	request.ephemeralPublicKey = resultStep1.ephemeralPublicKey;
	request.extras = extras;
	
	if (task.isCancelled) {
		NSError *error = [NSError errorWithDomain:PA2ErrorDomain code:PA2ErrorCodeOperationCancelled userInfo:nil];
		callback(nil, error);
		return task;
	}
	
	NSURLSessionDataTask *dataTask = [_client createActivation:request callback:^(PA2RestResponseStatus status, PA2CreateActivationResponse *response, NSError *clientError) {
		
		// Network error occurred
		if (clientError) {
			callback(nil, clientError);
			return;
		}
		
		// Network communication completed correctly
		if (status == PA2RestResponseStatus_OK) {
			
			// Prepare crypto module request
			PA2ActivationStep2Param *paramStep2 = [[PA2ActivationStep2Param alloc] init];
			paramStep2.activationId = response.activationId;
			paramStep2.ephemeralNonce = response.activationNonce;
			paramStep2.ephemeralPublicKey = response.ephemeralPublicKey;
			paramStep2.encryptedServerPublicKey = response.encryptedServerPublicKey;
			paramStep2.serverDataSignature = response.encryptedServerPublicKeySignature;
			
			// Obtain crypto module response
			PA2ActivationStep2Result *resultStep2 = [_session validateActivationResponse:paramStep2];
			
			// Everything was OK
			if (resultStep2) {
				callback(resultStep2.hkDevicePublicKey, nil);
			}
			// Error occurred
			else {
				NSError *error = [NSError errorWithDomain:PA2ErrorDomain code:PA2ErrorCodeInvalidActivationData userInfo:nil];
				callback(nil, error);
			}
			
		}
		// Activation error occurred
		else {
			NSError *error = [NSError errorWithDomain:PA2ErrorDomain code:PA2ErrorCodeInvalidActivationData userInfo:nil];
			callback(nil, error);
		}
	}];
	task.dataTask = dataTask;
	return task;
}

- (PA2OperationTask*) createActivationWithName:(NSString*)name
							identityAttributes:(NSDictionary<NSString*,NSString*>*)identityAttributes
								  customSecret:(NSString*)customSecret
										extras:(NSString*)extras
							  customAttributes:(NSDictionary<NSString*,NSString*>*)customAttributes
										   url:(NSURL*)url
								   httpHeaders:(NSDictionary*)httpHeaders
									  callback:(void(^)(NSString * activationFingerprint, NSError * error))callback {
	
	PA2OperationTask *task = [[PA2OperationTask alloc] init];
	
	// Check for the session setup
	if (!_session.hasValidSetup) {
		[PowerAuthSDK throwInvalidConfigurationException];
	}
	
	// Check if activation may be started
	if (_session.hasPendingActivation) {
		NSError *error = [NSError errorWithDomain:PA2ErrorDomain code:PA2ErrorCodeInvalidActivationState userInfo:nil];
		callback(nil, error);
		[task cancel];
		return task;
	}
	
	[_session resetSession];
	
	// Prepare identity attributes token
	NSData *identityAttributesData = [_session prepareKeyValueDictionaryForDataSigning:identityAttributes];
	NSString *identityAttributesString = [identityAttributesData base64EncodedStringWithOptions:kNilOptions];
	
	// Prepare crypto module request
	PA2ActivationStep1Param *paramStep1 = [[PA2ActivationStep1Param alloc] init];
	paramStep1.activationIdShort = identityAttributesString;
	paramStep1.activationOtp = customSecret;
	paramStep1.activationSignature = nil;
	
	// Obtain crypto module response
	PA2ActivationStep1Result *resultStep1 = [_session startActivation:paramStep1];
	
	// Perform exchange over PowerAuth 2.0 Standard RESTful API
	PA2CreateActivationRequest *powerauth = [[PA2CreateActivationRequest alloc] init];
	powerauth.activationIdShort = paramStep1.activationIdShort;
	powerauth.activationName = name;
	powerauth.activationNonce = resultStep1.activationNonce;
	powerauth.applicationKey = _configuration.appKey;
	powerauth.applicationSignature = resultStep1.applicationSignature;
	powerauth.encryptedDevicePublicKey = resultStep1.cDevicePublicKey;
	powerauth.ephemeralPublicKey = resultStep1.ephemeralPublicKey;
	powerauth.extras = extras;
	
	PA2DirectCreateActivationRequest * request = [[PA2DirectCreateActivationRequest alloc] init];
	request.identity = identityAttributes;
	request.customAttributes = customAttributes;
	request.powerauth = powerauth;
	
	NSData *requestData = [NSJSONSerialization dataWithJSONObject:[request toDictionary]
														  options:kNilOptions
															error:nil];
	
	PA2RequestResponseNonPersonalizedEncryptor *encryptor = [_encryptorFactory buildRequestResponseNonPersonalizedEncryptor];
	
	PA2Request *encryptedRequest = [encryptor encryptRequestData:requestData error:nil];
	NSData *encryptedRequestData = [NSJSONSerialization dataWithJSONObject:[encryptedRequest toDictionary]
																   options:kNilOptions
																	 error:nil];
	
	if (task.isCancelled) {
		NSError *error = [NSError errorWithDomain:PA2ErrorDomain code:PA2ErrorCodeOperationCancelled userInfo:nil];
		callback(nil, error);
		return task;
	}
	
	NSURLSessionDataTask *dataTask = [_client postToUrl:url data:encryptedRequestData headers:httpHeaders completion:^(NSData * httpData, NSURLResponse * response, NSError * clientError) {
		
		// Network error occurred
		if (clientError) {
			callback(nil, clientError);
			return;
		}
		
		NSDictionary *encryptedResponseDictionary = [NSJSONSerialization JSONObjectWithData:httpData options:kNilOptions error:nil];
		PA2Response *encryptedResponse = [[PA2Response alloc] initWithDictionary:encryptedResponseDictionary
															  responseObjectType:[PA2NonPersonalizedEncryptedObject class]];
		
		// Network communication completed correctly
		if (encryptedResponse.status == PA2RestResponseStatus_OK) {
			
			NSData *decryptedResponseData = [encryptor decryptResponse:encryptedResponse error:nil];
			NSDictionary *createActivationResponseDictionary = [NSJSONSerialization JSONObjectWithData:decryptedResponseData
																							   options:kNilOptions
																								 error:nil];
			
			PA2CreateActivationResponse *responseObject = [[PA2CreateActivationResponse alloc] initWithDictionary:createActivationResponseDictionary];
			
			// Prepare crypto module request
			PA2ActivationStep2Param *paramStep2 = [[PA2ActivationStep2Param alloc] init];
			paramStep2.activationId = responseObject.activationId;
			paramStep2.ephemeralNonce = responseObject.activationNonce;
			paramStep2.ephemeralPublicKey = responseObject.ephemeralPublicKey;
			paramStep2.encryptedServerPublicKey = responseObject.encryptedServerPublicKey;
			paramStep2.serverDataSignature = responseObject.encryptedServerPublicKeySignature;
			
			// Obtain crypto module response
			PA2ActivationStep2Result *resultStep2 = [_session validateActivationResponse:paramStep2];
			
			// Everything was OK
			if (resultStep2) {
				callback(resultStep2.hkDevicePublicKey, nil);
			}
			// Error occurred
			else {
				NSError *error = [NSError errorWithDomain:PA2ErrorDomain code:PA2ErrorCodeInvalidActivationData userInfo:nil];
				callback(nil, error);
			}
			
		}
		// Activation error occurred
		else {
			NSError *error = [NSError errorWithDomain:PA2ErrorDomain code:PA2ErrorCodeInvalidActivationData userInfo:nil];
			callback(nil, error);
		}
	}];
	task.dataTask = dataTask;
	return task;
	
}

- (PA2OperationTask*) createActivationWithName:(NSString*)name
							identityAttributes:(NSDictionary<NSString*,NSString*>*)identityAttributes
										   url:(NSURL*)url
									  callback:(void(^)(NSString * activationFingerprint, NSError * error))callback {
	return [self createActivationWithName:name
					   identityAttributes:identityAttributes
							 customSecret:@"00000-00000" // aka "zero code"
								   extras:nil
						 customAttributes:nil
									  url:url
							  httpHeaders:nil
								 callback:callback];
}

- (BOOL) commitActivationWithPassword:(NSString*)password
								error:(NSError**)error {
	PowerAuthAuthentication *authentication = [[PowerAuthAuthentication alloc] init];
	authentication.useBiometry = YES;
	authentication.usePossession = YES;
	authentication.usePassword = password;
	return [self commitActivationWithAuthentication:authentication error:error];
}

- (BOOL) commitActivationWithAuthentication:(PowerAuthAuthentication*)authentication
									  error:(NSError**)error {
	
	// Check for the session setup
	if (!_session.hasValidSetup) {
		[PowerAuthSDK throwInvalidConfigurationException];
	}
	
	// Check if there is a pending activation present and not an already existing valid activation
	if (!_session.hasPendingActivation || _session.hasValidActivation) {
		if (error) {
			*error = [NSError errorWithDomain:PA2ErrorDomain code:PA2ErrorCodeInvalidActivationState userInfo:nil];
		}
		return NO;
	}
	
	// Prepare key encryption keys
	NSData *possessionKey = nil;
	NSData *biometryKey = nil;
	PA2Password *knowledgeKey = nil;
	if (authentication.usePossession) {
		possessionKey = [self deviceRelatedKey];
	}
	if (authentication.useBiometry) {
		biometryKey = [PA2Session generateSignatureUnlockKey];
	}
	if (authentication.usePassword) {
		knowledgeKey = [PA2Password passwordWithString:authentication.usePassword];
	}
	
	// Prepare signature unlock keys structure
	PA2SignatureUnlockKeys *keys = [[PA2SignatureUnlockKeys alloc] init];
	keys.possessionUnlockKey = possessionKey;
	keys.biometryUnlockKey = biometryKey;
	keys.userPassword = knowledgeKey;
	
	// Complete the activation
	BOOL result = [_session completeActivation:keys];
	
	// Propagate error
	if (!result && error) {
		*error = [NSError errorWithDomain:PA2ErrorDomain code:PA2ErrorCodeInvalidActivationState userInfo:nil];
	}
	
	// Store keys and session state in Keychain
	if (result) {
		[_statusKeychain deleteDataForKey:_configuration.instanceId];
		[_biometryOnlyKeychain deleteDataForKey:_biometryKeyIdentifier];
		
		[_statusKeychain addValue:_session.serializedState forKey:_configuration.instanceId];
		if (biometryKey) {
			[_biometryOnlyKeychain addValue:biometryKey forKey:_biometryKeyIdentifier useTouchId:YES];
		}
	}
	
	// Return result
	return result;
}

#pragma mark Getting activations state

- (PA2OperationTask*) fetchActivationStatusWithCallback:(void(^)(PA2ActivationStatus *status, NSDictionary *customObject, NSError *error))callback {
	
	PA2OperationTask *task = [[PA2OperationTask alloc] init];
	
	// Check for the session setup
	if (!_session.hasValidSetup) {
		[PowerAuthSDK throwInvalidConfigurationException];
	}
	
	// Check if there is an activation present, valid or pending
	if (!_session.hasValidActivation && !_session.hasPendingActivation) {
		NSError *error = [NSError errorWithDomain:PA2ErrorDomain code:PA2ErrorCodeMissingActivation userInfo:nil];
		callback(nil, nil, error);
		[task cancel];
		return task;
	}
	// Handle the case of a pending activation locally.
	// Note that we cannot use the  generic logics here since the transport key is not established yet.
	else if (_session.hasPendingActivation) {
		NSError *error = [NSError errorWithDomain:PA2ErrorDomain code:PA2ErrorCodeActivationPending userInfo:nil];
		callback(nil, nil, error);
		[task cancel];
		return task;
	}
	
	if (task.isCancelled) {
		NSError *error = [NSError errorWithDomain:PA2ErrorDomain code:PA2ErrorCodeOperationCancelled userInfo:nil];
		callback(nil, nil, error);
		return task;
	}
	
	// Perform the server request
	PA2ActivationStatusRequest *request = [[PA2ActivationStatusRequest alloc] init];
	request.activationId = _session.activationIdentifier;
	NSURLSessionDataTask *dataTask = [_client getActivationStatus:request callback:^(PA2RestResponseStatus status, PA2ActivationStatusResponse *response, NSError *clientError) {
		
		// Network communication completed correctly
		if (status == PA2RestResponseStatus_OK) {
			
			// Prepare unlocking key (possession factor only)
			PA2SignatureUnlockKeys *keys = [[PA2SignatureUnlockKeys alloc] init];
			keys.possessionUnlockKey = [self deviceRelatedKey];
			
			// Attempt to decode the activation status
			PA2ActivationStatus *status = [_session decodeActivationStatus:response.encryptedStatusBlob keys:keys];
			
			// Everything was OK
			if (status) {
				callback(status, response.customObject, nil);
			}
			// Error occurred when decoding status
			else {
				NSError *error = [NSError errorWithDomain:PA2ErrorDomain code:PA2ErrorCodeInvalidActivationData userInfo:nil];
				callback(nil, response.customObject, error);
			}
			
		}
		// Network error occurred
		else {
			callback(nil, nil, clientError);
		}
	}];
	task.dataTask = dataTask;
	return task;
}

#pragma mark Removing an activation

- (PA2OperationTask*) removeActivationWithAuthentication:(PowerAuthAuthentication*)authentication
												callback:(void(^)(NSError *error))callback {
	
	PA2OperationTask *task = [[PA2OperationTask alloc] init];
	
	// Check for the session setup
	if (!_session.hasValidSetup) {
		[PowerAuthSDK throwInvalidConfigurationException];
	}
	
	// Check if there is an activation present
	if (!_session.hasValidActivation && _session.hasPendingActivation) {
		NSError *error = [NSError errorWithDomain:PA2ErrorDomain
											 code:PA2ErrorCodeMissingActivation
										 userInfo:nil];
		callback(error);
		[task cancel];
		return task;
	}
	
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		
		// Compute authorization header based on constants from the specification.
		NSError *error = nil;
		PA2AuthorizationHttpHeader *httpHeader = [self requestSignatureWithAuthentication:authentication method:@"POST" uriId:@"/pa/activation/remove" body:nil error:&error];
		if (error) {
			callback(error);
			return;
		}
		
		if (task.isCancelled) {
			NSError *error = [NSError errorWithDomain:PA2ErrorDomain code:PA2ErrorCodeOperationCancelled userInfo:nil];
			callback(error);
			return;
		}
		
		// Perform the server request
		NSURLSessionDataTask *dataTask = [_client removeActivationSignatureHeader:httpHeader callback:^(PA2RestResponseStatus status, NSError *clientError) {
			// Network communication completed correctly
			if (status == PA2RestResponseStatus_OK) {
				callback(nil);
			}
			// Network error occurred
			else {
				callback(clientError);
			}
		}];
		
		task.dataTask = dataTask;
		
	});
	
	
	return task;
}

#pragma mark Computing signatures

- (PA2AuthorizationHttpHeader*) requestGetSignatureWithAuthentication:(PowerAuthAuthentication*)authentication
																uriId:(NSString*)uriId
															   params:(NSDictionary<NSString*, NSString*>*)params
																error:(NSError**)error {
	NSData *data = [_session prepareKeyValueDictionaryForDataSigning:params];
	return [self requestSignatureWithAuthentication:authentication
											 method:@"GET"
											  uriId:uriId
											   body:data
											  error:error];
}

- (PA2AuthorizationHttpHeader*) requestSignatureWithAuthentication:(PowerAuthAuthentication*)authentication
															method:(NSString*)method
															 uriId:(NSString*)uriId
															  body:(NSData*)body
															 error:(NSError**)error {
	return [self requestSignatureWithAuthentication:authentication
										vaultUnlock:NO
											 method:method
											  uriId:uriId
											   body:body
											  error:error];
}

- (PA2AuthorizationHttpHeader*) requestSignatureWithAuthentication:(PowerAuthAuthentication*)authentication
													   vaultUnlock:(BOOL)vaultUnlock
															method:(NSString*)method
															 uriId:(NSString*)uriId
															  body:(NSData*)body
															 error:(NSError**)error {
	
	// Check for the session setup
	if (!_session.hasValidSetup) {
		[PowerAuthSDK throwInvalidConfigurationException];
	}
	
	// Check if there is an activation present
	if (!_session.hasValidActivation && _session.hasPendingActivation) {
		if (error) {
			*error = [NSError errorWithDomain:PA2ErrorDomain code:PA2ErrorCodeMissingActivation userInfo:nil];
		}
		return nil;
	}
	
	// Generate signature key encryption keys
	BOOL userCancelled = NO;
	PA2SignatureUnlockKeys *keys = [self signatureKeysForAuthentication:authentication userCancelled:&userCancelled];
	if (keys == nil) { // Unable to fetch Touch ID related record - maybe user or iOS canacelled the operation?
		if (error) {
			*error = [NSError errorWithDomain:PA2ErrorDomain code:PA2ErrorCodeTouchIDCancel userInfo:nil];
		}
		return nil;
	}
	
	// Determine authentication factor type
	PA2SignatureFactor factor = [self determineSignatureFactorForAuthentication:authentication withVaultUnlock:vaultUnlock];
	
	// Compute authorization header for provided values and return result.
	NSString *httpHeaderValue = [_session httpAuthHeaderValueForBody:body httpMethod:method uri:uriId keys:keys factor:factor];
	
	// Update keychain values after each successful calculations
	[_statusKeychain updateValue:[_session serializedState] forKey:_configuration.instanceId];
	
	if (httpHeaderValue == nil && error) {
		*error = [NSError errorWithDomain:PA2ErrorDomain code:PA2ErrorCodeSignatureError userInfo:nil];
	}
	
	return [[PA2AuthorizationHttpHeader alloc] initWithValue:httpHeaderValue];
	
}

#pragma mark Activation sign in factor management

- (BOOL) unsafeChangePasswordFrom:(NSString*)oldPassword
							   to:(NSString*)newPassword {
	
	BOOL result = [_session changeUserPassword:[PA2Password passwordWithString:oldPassword]
								   newPassword:[PA2Password passwordWithString:newPassword]];
	if (result) {
		[_statusKeychain updateValue:[_session serializedState] forKey:_configuration.instanceId];
	}
	return result;
}

- (PA2OperationTask*) changePasswordFrom:(NSString*)oldPassword
									  to:(NSString*)newPassword
								callback:(void(^)(NSError *error))callback {
	
	// Setup a new authentication object
	PowerAuthAuthentication *authentication = [[PowerAuthAuthentication alloc] init];
	authentication.usePossession = YES;
	authentication.usePassword = oldPassword;
	authentication.useBiometry = NO;
	
	return [self fetchEncryptedVaultUnlockKey:authentication callback:^(NSString *encryptedEncryptionKey, NSError *error) {
		if (!error) {
			// Let's change the password
			BOOL result = [_session changeUserPassword:[PA2Password passwordWithString:oldPassword]
										   newPassword:[PA2Password passwordWithString:newPassword]];
			if (result) {
				[_statusKeychain updateValue:[_session serializedState] forKey:_configuration.instanceId];
				callback(nil);
			} else {
				NSError *error = [NSError errorWithDomain:PA2ErrorDomain code:PA2ErrorCodeInvalidActivationState userInfo:nil];
				callback(error);
			}
		} else {
			callback(error);
		}
	}];
}

- (PA2OperationTask*) addBiometryFactor:(NSString*)password
							   callback:(void(^)(NSError *error))callback {
	
	// Check if Touch ID can be used
	if (![PA2Keychain canUseTouchId]) {
		NSError *error = [NSError errorWithDomain:PA2ErrorDomain code:PA2ErrorCodeTouchIDNotAvailable userInfo:nil];
		callback(error);
		PA2OperationTask *task = [[PA2OperationTask alloc] init]; // tmp task
		[task cancel];
		return task;
	}
	
	// Compute authorization header based on constants from the specification.
	PowerAuthAuthentication *authentication = [[PowerAuthAuthentication alloc] init];
	authentication.usePossession	= YES;
	authentication.useBiometry		= NO;
	authentication.usePassword		= password;
	
	return [self fetchEncryptedVaultUnlockKey:authentication callback:^(NSString *encryptedEncryptionKey, NSError *error) {
		if (!error) {
			
			if (encryptedEncryptionKey == nil) {
				NSError *error = [NSError errorWithDomain:PA2ErrorDomain
													 code:PA2ErrorCodeInvalidActivationState
												 userInfo:nil];
				callback(error);
				return;
			}
			
			// Let's add the biometry key
			PA2SignatureUnlockKeys *keys = [[PA2SignatureUnlockKeys alloc] init];
			keys.possessionUnlockKey = [self deviceRelatedKey];
			keys.biometryUnlockKey = [PA2Session generateSignatureUnlockKey];
			
			BOOL result = [_session addBiometryFactor:encryptedEncryptionKey
												 keys:keys];
			// Propagate error
			if (!result) {
				NSError *error = [NSError errorWithDomain:PA2ErrorDomain
													 code:PA2ErrorCodeInvalidActivationState
												 userInfo:nil];
				callback(error);
			} else {
				// Update keychain values after each successful calculations
				[_statusKeychain updateValue:[_session serializedState] forKey:_configuration.instanceId];
				[_biometryOnlyKeychain deleteDataForKey:_biometryKeyIdentifier];
				[_biometryOnlyKeychain addValue:keys.biometryUnlockKey forKey:_biometryKeyIdentifier useTouchId:YES];
				callback(nil);
			}
		} else {
			callback(error);
		}
	}];
}

- (BOOL) hasBiometryFactor {
	// Check for the session setup
	if (!_session.hasValidSetup) {
		[PowerAuthSDK throwInvalidConfigurationException];
	}
	BOOL hasValue = [_biometryOnlyKeychain containsDataForKey:_biometryKeyIdentifier];
	hasValue = hasValue && [_session hasBiometryFactor];
	return hasValue;
}

- (BOOL) removeBiometryFactor {
	// Check for the session setup
	if (!_session.hasValidSetup) {
		[PowerAuthSDK throwInvalidConfigurationException];
	}
	BOOL result = [_session removeBiometryFactor];
	if (result) {
		// Update keychain values after each successful calculations
		[_statusKeychain updateValue:[_session serializedState] forKey:_configuration.instanceId];
		[_biometryOnlyKeychain deleteDataForKey:_biometryKeyIdentifier];
	}
	return result;
}

- (void) unlockBiometryKeysWithPrompt:(NSString*)prompt
                            withBlock:(void(^)(NSDictionary<NSString*, NSData*> *keys, bool userCanceled))block {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        OSStatus status;
        bool userCanceled;
        NSDictionary *keys = [_biometryOnlyKeychain allItemsWithPrompt:prompt withStatus:&status];
        userCanceled = status == errSecUserCanceled;
        block(keys, userCanceled);
    });
}

#pragma mark Secure vault support


- (PA2OperationTask*) fetchEncryptionKey:(PowerAuthAuthentication*)authentication
								   index:(UInt64)index
								callback:(void(^)(NSData *encryptionKey, NSError *error))callback {
	return [self fetchEncryptedVaultUnlockKey:authentication callback:^(NSString *encryptedEncryptionKey, NSError *error) {
		if (!error) {
			
			if (encryptedEncryptionKey == nil) {
				NSError *error = [NSError errorWithDomain:PA2ErrorDomain
													 code:PA2ErrorCodeInvalidActivationState
												 userInfo:nil];
				callback(nil, error);
				return;
			}
			
			// Let's unlock encryption key
			PA2SignatureUnlockKeys *keys = [[PA2SignatureUnlockKeys alloc] init];
			keys.possessionUnlockKey = [self deviceRelatedKey];
			NSData *key = [_session deriveCryptographicKeyFromVaultKey:encryptedEncryptionKey
																  keys:keys
															  keyIndex:index];
			// Propagate error
			if (key == nil) {
				NSError *error = [NSError errorWithDomain:PA2ErrorDomain
													 code:PA2ErrorCodeInvalidActivationData
												 userInfo:nil];
				callback(nil, error);
			} else {
				callback(key, nil);
			}
		} else {
			callback(nil, error);
		}
	}];
}

#pragma mark Asymmetric signatures

- (PA2OperationTask*) signDataWithDevicePrivateKey:(PowerAuthAuthentication*)authentication
											  data:(NSData*)data
										  callback:(void(^)(NSData *signature, NSError *error))callback {
	return [self fetchEncryptedVaultUnlockKey:authentication callback:^(NSString *encryptedEncryptionKey, NSError *error) {
		if (!error) {
			
			if (encryptedEncryptionKey == nil) {
				NSError *error = [NSError errorWithDomain:PA2ErrorDomain
													 code:PA2ErrorCodeInvalidActivationState
												 userInfo:nil];
				callback(nil, error);
				return;
			}
			
			// Let's sign the data
			PA2SignatureUnlockKeys *keys = [[PA2SignatureUnlockKeys alloc] init];
			keys.possessionUnlockKey = [self deviceRelatedKey];
			NSData *signature = [_session signDataWithDevicePrivateKey:encryptedEncryptionKey
																  keys:keys
																  data:data];
			// Propagate error
			if (signature == nil) {
				NSError *error = [NSError errorWithDomain:PA2ErrorDomain
													 code:PA2ErrorCodeInvalidActivationData
												 userInfo:nil];
				callback(nil, error);
			} else {
				callback(signature, nil);
			}
		} else {
			callback(nil, error);
		}
	}];
}

- (nonnull PA2OperationTask*) validatePasswordCorrect:(NSString*)password callback:(void(^)(NSError * error))callback {
	PowerAuthAuthentication *authentication = [[PowerAuthAuthentication alloc] init];
	authentication.usePossession = YES;
	authentication.useBiometry = NO;
	authentication.usePassword = password;
	return [self fetchEncryptedVaultUnlockKey:authentication callback:^(NSString *encryptedEncryptionKey, NSError *error) {
		callback(error);
	}];
}

@end
