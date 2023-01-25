# Copyright 2022 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# tfdoc:file:description Folder resources.

locals {
  _vpc_sc_vpc_accessible_services = yamldecode(
    file("${var.data_dir}/vpc-sc/restricted-services.yaml")
  )
  _vpc_sc_restricted_services = yamldecode(
    file("${var.data_dir}/vpc-sc/restricted-services.yaml")
  )

  groups = {
    for k, v in var.groups : k => "${v}@${var.organization.domain}"
  }
  groups_iam = {
    for k, v in local.groups : k => "group:${v}"
  }
  group_iam = {
    (local.groups.data-engineers) = [
      "roles/editor",
    ]
  }

  vpc_sc_resources = [
    for k, v in data.google_projects.folder-projects.projects : format("projects/%s", v.number)
  ]

  log_sink_destinations = var.enable_features.log_sink ? merge(
    # use the same dataset for all sinks with `bigquery` as  destination
    { for k, v in var.log_sinks : k => module.log-export-dataset.0 if v.type == "bigquery" },
    # use the same gcs bucket for all sinks with `storage` as destination
    { for k, v in var.log_sinks : k => module.log-export-gcs.0 if v.type == "storage" },
    # use separate pubsub topics and logging buckets for sinks with
    # destination `pubsub` and `logging`
    module.log-export-pubsub,
    module.log-export-logbucket
  ) : null
}

module "folder" {
  source        = "../../../modules/folder"
  folder_create = var.folder_create != null
  parent        = try(var.folder_create.parent, null)
  name          = try(var.folder_create.display_name, null)
  id            = var.folder_id
  iam = {
    "roles/owner"                          = ["serviceAccount:${var.bootstrap_service_account}"]
    "roles/resourcemanager.projectCreator" = ["serviceAccount:${var.bootstrap_service_account}"]
  }
  group_iam              = local.group_iam
  org_policies_data_path = "${var.data_dir}/org-policies"
  firewall_policy_factory = {
    cidr_file   = "${var.data_dir}/firewall-policies/cidrs.yaml"
    policy_name = "${var.prefix}-fw-policy"
    rules_file  = "${var.data_dir}/firewall-policies/hierarchical-policy-rules.yaml"
  }
  logging_sinks = var.enable_features.log_sink ? {
    for name, attrs in var.log_sinks : name => {
      bq_partitioned_table = attrs.type == "bigquery"
      destination          = local.log_sink_destinations[name].id
      filter               = attrs.filter
      type                 = attrs.type
    }
  } : null
}

#TODO VPCSC: Access levels 
data "google_projects" "folder-projects" {
  filter = "parent.id:${split("/", module.folder.id)[1]}"
}

module "vpc-sc" {
  source               = "../../../modules/vpc-sc"
  access_policy        = var.access_policy
  access_policy_create = var.access_policy_create
  access_levels        = var.vpc_sc_access_levels
  egress_policies      = var.vpc_sc_egress_policies
  ingress_policies     = var.vpc_sc_ingress_policies
  service_perimeters_regular = {
    shielded = {
      status = {
        access_levels       = keys(var.vpc_sc_access_levels)
        resources           = null #TODO local.vpc_sc_resources
        restricted_services = local._vpc_sc_restricted_services
        egress_policies     = keys(var.vpc_sc_egress_policies)
        ingress_policies    = keys(var.vpc_sc_ingress_policies)
        vpc_accessible_services = {
          allowed_services   = local._vpc_sc_vpc_accessible_services
          enable_restriction = true
        }
      }
    }
  }
}
