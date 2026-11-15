# Runs the agent built by `bal build` (target/bin/foundry_hosted_agent.jar) on port 8088.
# Build the image for linux/amd64, which Foundry hosted agents require:
#   bal build
#   docker build --platform linux/amd64 -t foundry-hosted-agent:v1 .
# No configuration is copied into the image: pass it when the container starts.
FROM eclipse-temurin:25-jre

RUN useradd --system --create-home --uid 10001 ballerina
WORKDIR /home/ballerina
COPY --chown=ballerina target/bin/foundry_hosted_agent.jar agent.jar
USER 10001

ENV PORT=8088
EXPOSE 8088
ENTRYPOINT ["java", "-jar", "agent.jar"]
