#!/usr/bin/env groovy
// ==============================================================================
// Auth Service — Python 3.12 / Flask
// ==============================================================================
// The only service that touches MySQL. Handles signup, login and bcrypt
// password hashing.
//
// Identical pipeline to the other two services — only the four configuration
// values below differ. That is the entire point of the shared library: a change
// to the security gate, the tagging scheme, or the GitOps handoff is made once
// and all three services inherit it.
// ==============================================================================

@Library('shared-library') _

microservicePipeline(
    serviceName: 'ivolve-auth-service',
    sourceDir: 'src/auth-service',
    language: 'python',

    ecrRegistry: '991216470475.dkr.ecr.us-east-1.amazonaws.com',
    awsRegion: 'us-east-1',

    gitRepo: 'github.com/WaleedDarwesh/CloudDevOpsProject.git',
    gitBranch: 'main',
    manifestDir: '04-Kubernetes/manifests',

    runSonar: true,

    // Strictest setting of the three services. This one handles credentials and
    // is the only path to the user database, so it gets no exemption.
    failOnCritical: true
)
