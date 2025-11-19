/**
 * Copyright 2021 Mantel Group Pty Ltd
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

# Compute the runner name to use for registration in GitLab.  We provide a default based on the GCP project name but it
# can be overridden if desired.
locals {
  ci_runner_gitlab_name_final = (var.ci_runner_gitlab_name != "" ? var.ci_runner_gitlab_name : "gcp-${var.gcp_project}")
}

# Service account for the Gitlab CI runner.  It doesn't run builds but it spawns other instances that do.
resource "google_service_account" "ci_runner" {
  project      = var.gcp_project
  account_id   = "${var.gcp_resource_prefix}-runner"
  display_name = "GitLab CI Runner"
}
resource "google_project_iam_member" "instanceadmin_ci_runner" {
  project = var.gcp_project
  role    = "roles/compute.instanceAdmin.v1"
  member  = "serviceAccount:${google_service_account.ci_runner.email}"
}
resource "google_project_iam_member" "networkadmin_ci_runner" {
  project = var.gcp_project
  role    = "roles/compute.networkAdmin"
  member  = "serviceAccount:${google_service_account.ci_runner.email}"
}
resource "google_project_iam_member" "securityadmin_ci_runner" {
  project = var.gcp_project
  role    = "roles/compute.securityAdmin"
  member  = "serviceAccount:${google_service_account.ci_runner.email}"
}
resource "google_project_iam_member" "logwriter_ci_runner" {
  project = var.gcp_project
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.ci_runner.email}"
}

# Service account for Gitlab CI build instances that are dynamically spawned by the runner.
resource "google_service_account" "ci_worker" {
  project      = var.gcp_project
  account_id   = "${var.gcp_resource_prefix}-worker"
  display_name = "GitLab CI Worker"
}

# Allow GitLab CI runner to use the worker service account.
resource "google_service_account_iam_member" "ci_worker_ci_runner" {
  service_account_id = google_service_account.ci_worker.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.ci_runner.email}"
}

# Cache for the Gitlab CI runner
resource "google_storage_bucket" "cache" {
    name          = join("-", [local.ci_runner_gitlab_name_final, "cache"])
    location      = "EU"
    force_destroy = true

    lifecycle_rule {
        condition {
            age = "30"
        }
        action {
            type = "Delete"
        }
    }
}
resource "google_service_account" "cache-user" {
    account_id = join("-", [local.ci_runner_gitlab_name_final, "sa"])
}
resource "google_service_account_key" "cache-user" {
    service_account_id = google_service_account.cache-user.name
    public_key_type    = "TYPE_X509_PEM_FILE"
}
resource "google_project_iam_member" "project" {
    project = var.gcp_project
    role    = "roles/storage.objectAdmin"
    member  = format("serviceAccount:%s", google_service_account.cache-user.email)
}

resource "google_compute_instance" "ci_runner" {
  project      = var.gcp_project
  name         = "${var.gcp_resource_prefix}-runner"
  machine_type = var.ci_runner_instance_type
  zone         = var.gcp_zone

  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image = "${var.ci_runner_machine_image}"
      size  = var.ci_runner_disk_size
      type  = "pd-standard"
    }
  }

  network_interface {
    network    = var.ci_runner_network
    subnetwork = var.ci_runner_subnetwork


    access_config {
      // Ephemeral IP
    }
  }

  metadata_startup_script = <<SCRIPT
set -e

echo "Installing GitLab CI Runner"
curl -L https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.rpm.sh | sudo bash
sudo yum install -y gitlab-runner
sudo dnf install -y openssh-server openssh

echo "Installing docker machine."
curl -L https://gitlab-docker-machine-downloads.s3.amazonaws.com/v0.16.2-gitlab.22/docker-machine-Linux-x86_64 -o /tmp/docker-machine
sudo install /tmp/docker-machine /usr/local/bin/docker-machine

echo "Verifying docker-machine and generating SSH keys ahead of time."
docker-machine create --driver google \
    --google-project ${var.gcp_project} \
    --google-machine-type ${var.ci_worker_instance_type} \
    --google-zone ${var.gcp_zone} \
    --google-service-account ${google_service_account.ci_worker.email} \
    --google-scopes https://www.googleapis.com/auth/cloud-platform \
    --google-disk-type pd-ssd \
    --google-disk-size ${var.ci_worker_disk_size} \
    --google-machine-image ${var.ci_worker_machine_image} \
    --google-tags ${var.ci_worker_instance_tags} \
    --google-use-internal-ip \
    --google-network ${var.ci_runner_network} \
     %{if var.ci_runner_subnetwork != ""}--google-subnetwork ${var.ci_runner_subnetwork}%{endif} \
    ${var.gcp_resource_prefix}-test-machine

docker-machine rm -y ${var.gcp_resource_prefix}-test-machine

echo "Setting GitLab concurrency"
sed -i "s/concurrent = .*/concurrent = ${var.ci_concurrency}/" /etc/gitlab-runner/config.toml

echo ${google_service_account_key.cache-user.private_key} | base64 -d > /etc/gitlab-runner/key.json

echo "Registering GitLab CI runner with GitLab instance."
sudo gitlab-runner register -n \
    --description "${local.ci_runner_gitlab_name_final}" \
    --url ${var.gitlab_url} \
    --token ${var.ci_token} \
    --executor "docker+machine" \
    --docker-image "alpine:latest" \
    --tag-list "${var.ci_runner_gitlab_tags}" \
    --machine-machine-driver google \
    --docker-privileged=${var.docker_privileged} \
    --machine-idle-time ${var.ci_worker_idle_time} \
    --machine-machine-name "${var.gcp_resource_prefix}-worker-%s" \
    --machine-machine-options "google-project=${var.gcp_project}" \
    --machine-machine-options "google-machine-type=${var.ci_worker_instance_type}" \
    --machine-machine-options "google-machine-image=${var.ci_worker_machine_image}" \
    --machine-machine-options "google-zone=${var.gcp_zone}" \
    --machine-machine-options "google-service-account=${google_service_account.ci_worker.email}" \
    --machine-machine-options "google-scopes=https://www.googleapis.com/auth/cloud-platform" \
    --machine-machine-options "google-disk-type=pd-ssd" \
    --machine-machine-options "google-disk-size=${var.ci_worker_disk_size}" \
    --machine-machine-options "google-tags=${var.ci_worker_instance_tags}" \
    --cache-type gcs \
    --cache-shared \
    --cache-gcs-bucket-name ${google_storage_bucket.cache.name} \
    --cache-gcs-credentials-file /etc/gitlab-runner/key.json \
    --machine-machine-options "google-use-internal-ip" \
    --machine-machine-options "google-network=${var.ci_runner_network}" \
    %{if var.ci_runner_subnetwork != ""}--machine-machine-options "google-subnetwork=${var.ci_runner_subnetwork}"%{endif} \
    %{if var.pre_clone_script != ""}--pre-clone-script ${replace(format("%q", var.pre_clone_script), "$", "\\$")}%{endif} \
    %{if var.post_clone_script != ""}--post-clone-script ${replace(format("%q", var.post_clone_script), "$", "\\$")}%{endif} \
    %{if var.pre_build_script != ""}--pre-build-script ${replace(format("%q", var.pre_build_script), "$", "\\$")}%{endif} \
    %{if var.post_build_script != ""}--post-build-script ${replace(format("%q", var.post_build_script), "$", "\\$")}%{endif} \
    && true

echo "Setting FF_NETWORK_PER_BUILD feature flag"
sed -i '/^\[\[runners\]\]/a \  environment = ["FF_NETWORK_PER_BUILD=1"]' /etc/gitlab-runner/config.toml
sudo service gitlab-runner restart

sudo gitlab-runner verify

echo "GitLab CI Runner installation complete"
SCRIPT

  service_account {
    email  = google_service_account.ci_runner.email
    scopes = ["cloud-platform"]
  }
}
