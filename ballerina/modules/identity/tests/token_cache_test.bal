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

import ballerina/lang.runtime;
import ballerina/test;

const int T0 = 1800000000;

# A fake token source: counts fetches, can be told to fail, and issues tokens that live `lifetime` seconds.
isolated class FakeSource {
    private int fetches = 0;
    private boolean failing = false;
    private int now = T0;
    private final int lifetime;
    private final decimal delay;
    private final int? refreshOn;

    isolated function init(int lifetime = 3600, decimal delay = 0, int? refreshOn = ()) {
        self.lifetime = lifetime;
        self.delay = delay;
        self.refreshOn = refreshOn;
    }

    isolated function fetch(readonly & string[] scopes) returns AccessToken|Error {
        runtime:sleep(self.delay);
        lock {
            self.fetches += 1;
            if self.failing {
                return error Error("source unavailable", credential = "fake");
            }
            int? refreshOn = self.refreshOn;
            return refreshOn is int
                ? {token: string `token-${self.fetches}`, expiresOn: self.now + self.lifetime, refreshOn}
                : {token: string `token-${self.fetches}`, expiresOn: self.now + self.lifetime};
        }
    }

    isolated function clock() returns int {
        lock {
            return self.now;
        }
    }

    isolated function advance(int seconds) {
        lock {
            self.now += seconds;
        }
    }

    isolated function setFailing(boolean failing) {
        lock {
            self.failing = failing;
        }
    }

    isolated function fetchCount() returns int {
        lock {
            return self.fetches;
        }
    }
}

isolated function newCache(FakeSource 'source) returns TokenCache =>
    new (isolated function(readonly & string[] scopes) returns AccessToken|Error => 'source.fetch(scopes),
        isolated function() returns int => 'source.clock());

@test:Config
function testConcurrentCallersShareOneFetch() returns error? {
    FakeSource 'source = new (delay = 0.2);
    TokenCache cache = newCache('source);
    future<AccessToken|Error>[] calls = [];
    foreach int i in 0 ..< 50 {
        future<AccessToken|Error> call = start cache.getToken(["scope/.default"]);
        calls.push(call);
    }
    foreach future<AccessToken|Error> call in calls {
        AccessToken token = check wait call;
        test:assertEquals(token.token, "token-1");
    }
    test:assertEquals('source.fetchCount(), 1, "50 concurrent callers should cause exactly one fetch");
}

@test:Config
function testTokenIsCachedPerScopeSet() returns error? {
    FakeSource 'source = new;
    TokenCache cache = newCache('source);
    _ = check cache.getToken(["a/.default", "b/.default"]);
    _ = check cache.getToken(["b/.default", "a/.default"]);
    test:assertEquals('source.fetchCount(), 1, "scope order must not matter");
    _ = check cache.getToken(["c/.default"]);
    test:assertEquals('source.fetchCount(), 2, "another scope set needs its own token");
}

@test:Config
function testEarlyRefresh() returns error? {
    FakeSource 'source = new (lifetime = 3600);
    TokenCache cache = newCache('source);
    test:assertEquals((check cache.getToken(["s"])).token, "token-1");

    'source.advance(3600 - REFRESH_WINDOW - 1);
    test:assertEquals((check cache.getToken(["s"])).token, "token-1", "not yet due");

    'source.advance(2);
    test:assertEquals((check cache.getToken(["s"])).token, "token-2", "refreshed within the refresh window");
    test:assertEquals('source.fetchCount(), 2);
}

@test:Config
function testRefreshOnIsHonoured() returns error? {
    TokenCache cache = new (isolated function(readonly & string[] scopes) returns AccessToken|Error {
            AccessToken token = {token: "t", expiresOn: T0 + 7200, refreshOn: T0 + 3600};
            return token;
        },
        isolated function() returns int => T0);
    AccessToken first = check cache.getToken(["s"]);
    test:assertEquals(first.refreshOn, T0 + 3600);
    test:assertTrue(isDue(first, T0 + 3600), "a token is due at its refreshOn time");
    test:assertFalse(isDue(first, T0 + 3599));
}

@test:Config
function testFailedRefreshKeepsServingValidToken() returns error? {
    FakeSource 'source = new (lifetime = 3600);
    TokenCache cache = newCache('source);
    _ = check cache.getToken(["s"]);

    'source.advance(3600 - REFRESH_WINDOW + 1);
    'source.setFailing(true);
    test:assertEquals((check cache.getToken(["s"])).token, "token-1", "a failed refresh serves the valid token");
    test:assertEquals('source.fetchCount(), 2);

    'source.advance(REFRESH_RETRY_INTERVAL - 1);
    _ = check cache.getToken(["s"]);
    test:assertEquals('source.fetchCount(), 2, "no retry within the retry interval");

    'source.advance(1);
    _ = check cache.getToken(["s"]);
    test:assertEquals('source.fetchCount(), 3, "retried after the retry interval");

    'source.setFailing(false);
    'source.advance(REFRESH_RETRY_INTERVAL);
    test:assertEquals((check cache.getToken(["s"])).token, "token-4", "a later refresh succeeds");
}

@test:Config
function testExpiredTokenAndFailingSourceReturnsError() returns error? {
    FakeSource 'source = new (lifetime = 3600);
    TokenCache cache = newCache('source);
    _ = check cache.getToken(["s"]);
    'source.advance(3600);
    'source.setFailing(true);
    AccessToken|Error token = cache.getToken(["s"]);
    if token !is Error {
        test:assertFail("an expired token must not be served");
    }
    test:assertEquals(token.message(), "source unavailable");
}

@test:Config
function testFailedFetchIsSharedBriefly() returns error? {
    FakeSource 'source = new (delay = 0.2);
    'source.setFailing(true);
    TokenCache cache = newCache('source);
    future<AccessToken|Error>[] calls = [];
    foreach int i in 0 ..< 10 {
        future<AccessToken|Error> call = start cache.getToken(["scope/.default"]);
        calls.push(call);
    }
    foreach future<AccessToken|Error> call in calls {
        AccessToken|Error result = wait call;
        test:assertTrue(result is Error, "every caller gets the failure");
    }
    test:assertEquals('source.fetchCount(), 1, "callers waiting on a failed fetch must not each fetch again");

    'source.advance(FAILED_FETCH_CACHE_SECONDS);
    'source.setFailing(false);
    AccessToken token = check cache.getToken(["scope/.default"]);
    test:assertEquals('source.fetchCount(), 2, "the failure is remembered only briefly");
    test:assertEquals(token.token, "token-2");
}

@test:Config
function testEpochRefreshOnIsNotARefreshHint() returns error? {
    // azure-identity reports the epoch as refreshOn when the source gives no refresh hint. Such a token must be served
    // from the cache like any other, not fetched again on every call.
    FakeSource 'source = new (refreshOn = 0);
    TokenCache cache = newCache('source);
    _ = check cache.getToken(["scope/.default"]);
    'source.advance(60);
    AccessToken token = check cache.getToken(["scope/.default"]);
    test:assertEquals(token.token, "token-1");
    test:assertEquals('source.fetchCount(), 1, "a token with refreshOn = 0 must be served from the cache");
}
