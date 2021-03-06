/*
 * Copyright 2017 Lime - HighTech Solutions s.r.o.
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

package io.getlime.security.powerauth.networking.endpoints;

import com.google.gson.reflect.TypeToken;

import io.getlime.security.powerauth.networking.interfaces.IEndpointDefinition;
import io.getlime.security.powerauth.rest.api.model.entity.NonPersonalizedEncryptedPayloadModel;

/**
 * Generic endpoint for a non-personalized encrypted object transport.
 *
 * @author Petr Dvorak, petr@lime-company.eu
 */

public class PA2NonPersonalizedEncryptedEndpoint implements IEndpointDefinition<NonPersonalizedEncryptedPayloadModel> {

    private String url;

    /**
     * Create a new endpoint with given URL, suitable for sending non-personalized encrypted data to server.
     * @param url URL of the endpoint
     */
    public PA2NonPersonalizedEncryptedEndpoint(String url) {
        this.url = url;
    }

    @Override
    public String getEndpoint() {
        return url;
    }

    @Override
    public TypeToken<NonPersonalizedEncryptedPayloadModel> getResponseType() {
        return TypeToken.get(NonPersonalizedEncryptedPayloadModel.class);
    }
}
