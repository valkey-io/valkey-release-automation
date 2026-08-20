import unittest
from pathlib import Path

WORKFLOWS = Path(".github/workflows")


def workflow(name: str) -> str:
    return (WORKFLOWS / name).read_text(encoding="utf-8")


class ReleaseWorkflowCoverageTest(unittest.TestCase):
    def test_qualification_builds_every_non_publishing_family(self) -> None:
        text = workflow("qualify-release.yml")
        for contract in (
            "workflow_call:",
            "default: reusable",
            "source_sha: ${{ inputs.source_sha }}",
            "qualify-linux-x86-archives:",
            "qualify-linux-arm-archives:",
            "qualify-packages:",
            "publish: false",
            "qualification-summary:",
            "Enforce the complete release matrix",
            '"$X86_COUNT" -ne 2',
            '"$RPM_JOBS" -ne 30',
        ):
            self.assertIn(contract, text)

    def test_production_keeps_all_release_outputs(self) -> None:
        text = workflow("build-release.yml")
        for job in (
            "update-valkey-hashes:",
            "update-valkey-container:",
            "update-valkey-doc:",
            "update-valkey-helm:",
            "release-build-linux-x86-packages:",
            "release-build-linux-arm-packages:",
            "release-build-packages:",
            "update-try-valkey:",
            "update-valkey-website:",
            "trigger-valkey-bundle:",
        ):
            self.assertIn(job, text)
        self.assertIn("environment: release-publish", text)
        self.assertIn('SOURCE_SHA="$TAG_SHA"', text)
        self.assertIn('WORKFLOW_REF" != "refs/heads/main"', text)
        self.assertIn('"$APPROVER" != "$TRIGGERING_ACTOR"', text)
        self.assertIn('CURRENT_SHA=$(gh api "repos/${REPO}/commits/main"', text)
        self.assertIn('"$GITHUB_SHA" == "$CURRENT_SHA"', text)
        self.assertIn("Production automation is stale:", text)

    def test_archive_and_package_builds_use_exact_source_sha(self) -> None:
        archives = workflow("call-build-linux-archives.yml")
        packages = workflow("packages.yml")
        self.assertIn("ref: ${{ inputs.source_sha != '' && inputs.source_sha || inputs.version }}", archives)
        self.assertIn("HEAD_SHA=$(git rev-parse HEAD)", archives)
        self.assertIn("source_sha:", packages)
        self.assertIn("valkey/archive/${SHA}.tar.gz", packages)
        self.assertIn("SOURCE_SHA: ${{ inputs.source_sha }}", packages)

    def test_candidate_code_never_shares_a_job_with_oidc(self) -> None:
        archives = workflow("call-build-linux-archives.yml")
        try_valkey = workflow("update-try-valkey.yml")
        archives = "\n".join(line for line in archives.splitlines() if not line.lstrip().startswith("#"))
        try_valkey = "\n".join(line for line in try_valkey.splitlines() if not line.lstrip().startswith("#"))
        archive_build = archives.split("  publish-valkey:", 1)[0]
        archive_publish = archives.split("  publish-valkey:", 1)[1]
        try_build = try_valkey.split("  upload-try-valkey:", 1)[0]
        try_publish = try_valkey.split("  upload-try-valkey:", 1)[1]
        self.assertNotIn("id-token: write", archive_build)
        self.assertNotIn("Configure AWS credentials", archive_build)
        self.assertIn("persist-credentials: false", archive_build)
        self.assertIn("id-token: write", archive_publish)
        self.assertNotIn("Make Valkey", archive_publish)
        self.assertNotIn("id-token: write", try_build)
        self.assertNotIn("Configure AWS credentials", try_build)
        self.assertEqual(
            try_build.count("persist-credentials: false"),
            try_build.count("uses: actions/checkout@"),
        )
        self.assertIn("id-token: write", try_publish)
        self.assertNotIn("Build Try Valkey image", try_publish)

    def test_hash_and_website_commits_are_signed_off(self) -> None:
        hashes = workflow("update-valkey-hashes.yml")
        website = workflow("update-valkey-website.yml")
        self.assertIn("source_sha:", hashes)
        self.assertIn('SHA=$(jq -r', hashes)
        self.assertIn("git commit -s", hashes)
        self.assertEqual(website.count("git commit -s"), 2)

    def test_cross_repo_qualification_checks_out_automation_implementation(self) -> None:
        qualification = workflow("qualify-release.yml")
        packages = workflow("packages.yml")
        self.assertNotIn("inputs.automation_repo", qualification)
        self.assertNotIn("inputs.automation_ref", qualification)
        self.assertNotIn("automation_repo:", packages)
        self.assertNotIn("automation_ref:", packages)
        checkout_count = packages.count("uses: actions/checkout@")
        self.assertGreater(checkout_count, 0)
        self.assertEqual(
            packages.count("repository: ${{ job.workflow_repository }}"),
            checkout_count,
        )
        self.assertEqual(
            packages.count("ref: ${{ job.workflow_sha }}"),
            checkout_count,
        )
        self.assertNotIn("github.workflow_sha", qualification)
        self.assertNotIn("github.workflow_sha", packages)
        self.assertIn("AUTOMATION_SHA: ${{ job.workflow_sha }}", qualification)
        self.assertIn("AUTOMATION_REPO: ${{ job.workflow_repository }}", qualification)
        self.assertIn("automation_sha:", qualification)
        self.assertIn("value: ${{ jobs.validate-inputs.outputs.automation_sha }}", qualification)
        self.assertIn("ref: ${{ needs.validate-inputs.outputs.automation_sha }}", qualification)

    def test_production_helpers_use_the_approved_automation_revision(self) -> None:
        for name in (
            "update-valkey-container.yml",
            "update-try-valkey.yml",
            "update-valkey-website.yml",
            "update-valkey-helm.yml",
        ):
            text = workflow(name)
            self.assertIn("repository: ${{ job.workflow_repository }}", text, name)
            self.assertIn("ref: ${{ job.workflow_sha }}", text, name)
            self.assertNotIn(
                "repository: ${{ github.repository_owner }}/valkey-release-automation",
                text,
                name,
            )

    def test_release_path_uses_one_automation_approval(self) -> None:
        build = workflow("build-release.yml")
        packages = workflow("packages.yml")
        self.assertEqual(build.count("environment: release-publish"), 1)
        self.assertIn("release_gate_passed: true", build)
        self.assertIn("standalone-approval:", packages)
        self.assertIn("release_gate_passed:", packages)
        self.assertEqual(packages.count("environment: release-publish"), 1)

    def test_helm_update_is_reviewable_and_cannot_publish_a_chart(self) -> None:
        text = workflow("update-valkey-helm.yml")
        self.assertIn("draft: true", text)
        self.assertIn("permission-pull-requests: write", text)
        self.assertNotIn("packages/helm", text)
        self.assertNotIn("docker/build-push-action", text)


if __name__ == "__main__":
    unittest.main()
