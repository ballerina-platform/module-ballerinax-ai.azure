// Copyright (c) 2026 WSO2 LLC (http://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/time;

# Seconds before expiry at which a token is refreshed, when its source suggests no earlier time.
const int REFRESH_WINDOW = 300;
# Minimum seconds between two attempts to refresh a token that is still usable.
const int REFRESH_RETRY_INTERVAL = 30;
# A token with fewer seconds than this left is treated as expired, so it doesn't lapse mid-request.
const int EXPIRY_MARGIN = 10;
# Seconds a failed fetch is remembered when there is no usable token, so waiting callers get that error instead of
# each running their own fetch against a failing source.
const int FAILED_FETCH_CACHE_SECONDS = 5;

# Fetches a new token from the credential source.
type TokenFetcher isolated function (readonly & string[] scopes) returns AccessToken|Error;

# Returns the current time in epoch seconds.
type Clock isolated function () returns int;

type CacheEntry record {|
    AccessToken? token = ();
    # `true` while one caller refreshes a still-usable token
    boolean refreshing = false;
    # Epoch seconds of the last failed refresh, `0` if none
    int lastFailure = 0;
    # The last failed fetch without a usable token, and when it failed (epoch seconds)
    Error? fetchError = ();
    int fetchErrorAt = 0;
|};

# Caches tokens per scope set in front of a credential source.
#
# - Without a usable token, exactly one fetch runs, under the lock; concurrent callers wait for it. If it fails,
#   callers within `FAILED_FETCH_CACHE_SECONDS` get the same error instead of fetching again.
# - A token is refreshed early: at its `refreshOn` time, or `REFRESH_WINDOW` seconds before it expires. During an
#   early refresh other callers keep getting the still-usable token, and a failed refresh is retried at most every
#   `REFRESH_RETRY_INTERVAL` seconds.
isolated class TokenCache {
    private final TokenFetcher fetcher;
    private final Clock clock;
    private final map<CacheEntry> entries = {};

    isolated function init(TokenFetcher fetcher, Clock clock = currentTime) {
        self.fetcher = fetcher;
        self.clock = clock;
    }

    isolated function getToken(string[] scopes) returns AccessToken|Error {
        readonly & string[] requested = scopes.cloneReadOnly();
        string key = cacheKey(requested);
        lock {
            int now = self.clock();
            CacheEntry entry = self.entries[key] ?: {};
            self.entries[key] = entry;
            AccessToken? current = entry.token;
            if current is () || !isUsable(current, now) {
                Error? recentError = entry.fetchError;
                if recentError is Error && now - entry.fetchErrorAt < FAILED_FETCH_CACHE_SECONDS {
                    return recentError;
                }
                // Fetched while holding the lock, so concurrent callers wait for this one fetch.
                AccessToken|Error fetched = self.fetcher(requested);
                if fetched is AccessToken {
                    entry.token = fetched;
                    entry.lastFailure = 0;
                    entry.fetchError = ();
                } else {
                    entry.fetchError = fetched;
                    entry.fetchErrorAt = self.clock();
                }
                return fetched;
            }
            if !isDue(current, now) || entry.refreshing || now - entry.lastFailure < REFRESH_RETRY_INTERVAL {
                return current;
            }
            entry.refreshing = true;
        }

        // Early refresh, outside the lock: other callers keep using the current token meanwhile.
        AccessToken|Error refreshed = self.fetcher(requested);
        lock {
            CacheEntry entry = self.entries[key] ?: {};
            self.entries[key] = entry;
            entry.refreshing = false;
            if refreshed is AccessToken {
                entry.token = refreshed;
                entry.lastFailure = 0;
                return refreshed;
            }
            int now = self.clock();
            entry.lastFailure = now;
            AccessToken? current = entry.token;
            return current is AccessToken && isUsable(current, now) ? current : refreshed;
        }
    }
}

isolated function isUsable(AccessToken token, int now) returns boolean => token.expiresOn - now > EXPIRY_MARGIN;

isolated function isDue(AccessToken token, int now) returns boolean {
    int? refreshOn = token?.refreshOn;
    int refreshAt = refreshOn is int ? int:min(refreshOn, token.expiresOn - REFRESH_WINDOW)
        : token.expiresOn - REFRESH_WINDOW;
    return now >= refreshAt;
}

isolated function cacheKey(string[] scopes) returns string => string:'join(" ", ...scopes.sort());

isolated function currentTime() returns int => time:utcNow()[0];
