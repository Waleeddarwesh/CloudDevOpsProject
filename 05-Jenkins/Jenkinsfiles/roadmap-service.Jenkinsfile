#!/usr/bin/env groovy
// ==============================================================================
// Roadmap Service — Java 21 / Spring Boot 3.5.4
// ==============================================================================
// Stateless API serving the DevOps roadmap content. No database.
//
// The `java` language setting changes two things in the shared library:
//   * Unit tests run via `mvn test` and publish surefire XML reports
//   * SonarQube analysis uses sonar-maven-plugin rather than the standalone
//     scanner, so it picks up module structure and coverage from the POM
// ==============================================================================

@Library('shared-library') _

microservicePipeline(
    serviceName: 'ivolve-roadmap-service',
    sourceDir: 'src/roadmap-service',
    language: 'java',

    ecrRegistry: '991216470475.dkr.ecr.us-east-1.amazonaws.com',
    awsRegion: 'us-east-1',

    gitRepo: 'github.com/WaleedDarwesh/CloudDevOpsProject.git',
    gitBranch: 'main',
    manifestDir: '04-Kubernetes/manifests',

    runSonar: true,
    failOnCritical: true
)
