#!/usr/bin/env groovy
// ==============================================================================
// Frontend — Node.js 22 / Express 5 / EJS
// ==============================================================================
// The entire pipeline is ~15 lines because every stage lives in the shared
// library. See 05-Jenkins/vars/microservicePipeline.groovy.
//
// @Library('shared-library') loads the library configured in
//   Manage Jenkins → System → Global Pipeline Libraries
//
// The trailing underscore is REQUIRED. It is not a typo and not decoration:
// the @Library annotation must be attached to a statement, and `_` is the
// conventional no-op used for that. Omitting it produces
// "unable to resolve class" errors that give no hint about the real cause.
// ==============================================================================

@Library('shared-library') _

microservicePipeline(
    // ECR repository name AND the Kustomize image key. Must match:
    //   * ecr_repository_names in 02-Terraform/terraform.tfvars
    //   * the `name:` entry in 04-Kubernetes/manifests/kustomization.yaml
    serviceName: 'ivolve-frontend',

    // Docker build context, relative to the repository root.
    sourceDir: 'src/frontend',

    // Selects the unit-test and SonarQube strategy.
    language: 'node',

    // Replace 991216470475 with your own account, or read it from:
    //   terraform -chdir=02-Terraform output -raw ecr_registry
    ecrRegistry: '991216470475.dkr.ecr.us-east-1.amazonaws.com',
    awsRegion: 'us-east-1',

    // Where the updated manifest commit is pushed. No scheme — the credential
    // is injected in front of it by updateManifests.groovy.
    gitRepo: 'github.com/WaleedDarwesh/CloudDevOpsProject.git',
    gitBranch: 'main',
    manifestDir: '04-Kubernetes/manifests',

    runSonar: true,

    // Blocks the push when Trivy finds a CRITICAL vulnerability that HAS a fix.
    // Set false only as a documented, deliberate risk acceptance.
    failOnCritical: true
)
