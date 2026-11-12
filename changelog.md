# Change Log

This file documents all significant changes made to the Ballerina Azure AI package across releases.

## [Unreleased]

### Added
- Run an agent as a Microsoft Foundry hosted agent over the Foundry Invocations protocol (HTTP)
  - `azure:FoundryListener` serves `POST /invocations`, the optional `GET /invocations/{invocationId}` and
    `POST /invocations/{invocationId}/cancel` routes and the `GET /readiness` probe, on the `PORT` environment
    variable or port 8088
  - `azure:FoundryInvocationService` holds only the agent logic; the listener resolves the session and invocation
    IDs, sets the platform response headers, classifies errors and stops gracefully
  - `azure:FoundryContext` gives a resource the session and invocation IDs, the platform request headers and the
    `FOUNDRY_*` environment variables
  - The compiler plugin validates the resources of a `FoundryInvocationService`
  - An example, `foundry-hosted-agent`: an `ai:Agent` with Azure OpenAI and a Dockerfile

### Changed
- Move to Ballerina distribution 2201.14.1 and the `java25` platform. Version 1.6.0 requires Ballerina Swan Lake
  Update 14 (2201.14.x) or later
