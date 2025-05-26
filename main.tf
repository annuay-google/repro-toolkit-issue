/**
  * Copyright 2023 Google LLC
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

locals {
  envoy_jwt_uri            = "https://www.googleapis.com/service_accounts/v1/jwk/${var.jwt_issuer}"
  envoy_jwt_issuer         = var.jwt_issuer
  envoy_slurm_cluster_name = "projects/${var.project_id}/locations/${var.region}/clusters/${var.slurm_cluster_name}"

  envoy_pre_script_content = <<-EOT
    #!/bin/bash
    set -ex

    slurm_impersonation_token=""
    readonly API_ENDPOINT="http://localhost:6842/slurm/v0.0.42/ping/"
    readonly WAIT_INTERVAL=20
    readonly MAX_WAIT_TIME=1800
    readonly ENVOY_CONFIG='static_resources:
      listeners:
      - name: listener_0
        address:
          socket_address:
            address: 0.0.0.0
            port_value: 10000
        filter_chains:
        - filters:
          - name: envoy.filters.network.http_connection_manager
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
              stat_prefix: ingress_http
              route_config:
                name: local_route
                virtual_hosts:
                - name: local_service
                  domains: ["*"]
                  routes:
                  - match:
                      prefix: "/slurm/v0.0.42/job/submit"
                    route:
                      cluster: slurm_service
                    request_headers_to_add:
                    - header:
                        key: "X-SLURM-USER-TOKEN"
                        value: "SLURM_IMPERSONATION_TOKEN_PLACEHOLDER"
                      append: false
              http_filters:
              - name: envoy.filters.http.jwt_authn
                typed_config:
                  "@type": type.googleapis.com/envoy.extensions.filters.http.jwt_authn.v3.JwtAuthentication
                  providers:
                    cloud_gaia_jwt:
                      issuer: "${local.envoy_jwt_issuer}"
                      audiences:
                      - "${local.envoy_slurm_cluster_name}"
                      remote_jwks:
                        http_uri:
                          uri: "${local.envoy_jwt_uri}"
                          cluster: google_cloud_gaia_cluster
                          timeout: 1s
                        cache_duration:
                          seconds: 300
                      payload_in_metadata: "cloud_gaia_jwt"
                  rules:
                  - match:
                      prefix: "/slurm/v0.0.42/job/submit"
                    requires:
                      provider_name: "cloud_gaia_jwt"
              - name: envoy.filters.http.router
                typed_config:
                  "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
                  suppress_envoy_headers: false
      clusters:
      - name: slurm_service
        type: STRICT_DNS
        connect_timeout: 50s
        lb_policy: ROUND_ROBIN
        load_assignment:
          cluster_name: slurm_service
          endpoints:
          - lb_endpoints:
            - endpoint:
                address:
                  socket_address:
                    address: 127.0.0.1
                    port_value: 6842
      - name: google_cloud_gaia_cluster
        type: LOGICAL_DNS
        connect_timeout: 5s
        dns_lookup_family: V4_ONLY
        lb_policy: ROUND_ROBIN
        load_assignment:
          cluster_name: google_cloud_gaia_cluster
          endpoints:
          - lb_endpoints:
            - endpoint:
                address:
                  socket_address:
                    address: www.googleapis.com
                    port_value: 443
        transport_socket:
          name: envoy.transport_sockets.tls
          typed_config:
            "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.UpstreamTlsContext
            sni: www.googleapis.com
    '

    # Installs the Envoy
    install_envoy() {
      echo "Installing envoy"
      wget -O- https://apt.envoyproxy.io/signing.key \
        | gpg --dearmor -o /etc/apt/keyrings/envoy-keyring.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/envoy-keyring.gpg] https://apt.envoyproxy.io bookworm main" \
        | tee /etc/apt/sources.list.d/envoy.list
      apt-get update
      apt-get install envoy
      echo "Installed envoy version: $(envoy --version)"
      return 0
    }

    # Fetches the Slurm token using scontrol.
    #
    # Returns:
    #   0 if the token is fetched successfully, 1 if an error occurs.
    fetch_slurm_token() {
      echo "Fetching impersonation token..."

      token_line=$(scontrol token lifespan=infinite)
      if [[ $? -ne 0 ]] || [[ -z "$token_line" ]]; then
        echo "Error: Could not fetch token. scontrol token command failed."
        return 1
      fi

      # Extract the token from the output line
      # Response is of the form:
      # SLURM_JWT=eyJxxxxxxxxxY29tInf7a4_Ofa-g5r302aWfnSfkLfHI.j4
      slurm_impersonation_token=$(echo "$token_line" | cut -d'=' -f2)
      if [[ -z "$slurm_impersonation_token" ]] || [[ "$slurm_impersonation_token" == "$token_line" ]]; then
        echo "Error: Failed to extract token from output: $token_line"
        return 1
      fi
      echo "Slurm token fetched successfully: $slurm_impersonation_token"
      return 0
    }

    # Pings the Slurm API endpoint.
    #
    # Returns:
    #   0 if the ping call succeeds, 1 otherwise.
    ping_slurm_api() {
      echo "Pinging Slurm API..."
      token="$1"
      if [[ -z "$token" ]]; then
        echo "Error: Token is empty, can't ping Slurm API."
        return 1
      fi

      local http_code
      http_code=$(curl -s -o /dev/null -w "%%{http_code}" -X GET "$API_ENDPOINT" \
      -H "X-SLURM-USER-NAME:root" \
      -H "X-SLURM-USER-TOKEN:$token" || true)

      if [[ "$http_code" =~ ^2 ]]; then
        echo "Slurm REST API is ready."
        return 0
      fi
      echo "Slurm REST API ping call failed with http code $http_code."
      return 1
    }

    # Waits for the Slurm REST API to be ready.
    #
    # Returns:
    #   0 if the API is ready, 1 if the MAX_WAIT_TIME is reached
    wait_for_slurm_api() {
      local count=0
      local max_retries=$((MAX_WAIT_TIME / WAIT_INTERVAL))

      echo "Waiting for Slurm REST API to be ready..."

      while [[ "$count" -lt "$max_retries" ]]; do
        count=$((count + 1))
        echo "Attempting $count/$max_retries..."
        if fetch_slurm_token && ping_slurm_api "$slurm_impersonation_token"; then
          return 0
        fi
        echo "Waiting for Slurm REST API... ($((count * WAIT_INTERVAL)) seconds elapsed)"
        sleep "$WAIT_INTERVAL"
      done
      echo "Timeout: Slurm REST API not ready after $MAX_WAIT_TIME seconds."
      return 1
    }

    # Populates the Envoy configuration file.
    #
    # Args:
    #   $1: The slurm token.
    #
    # Returns:
    #   0 if the configuration is populated successfully, 1 if an error occurs.
    populate_envoy_config() {
      echo "Populating envoy configuration"
      token="$1"
      if [[ -z "$token" ]]; then
        echo "Error: Token is empty, can't populate envoy config."
        return 1
      fi
      # Slurm JWTs are Base64URL encoded and do not contain |
      # Slurm cluster name does not contain |
      envoy_config=$(echo "$${ENVOY_CONFIG}" \
        | sed "s|SLURM_IMPERSONATION_TOKEN_PLACEHOLDER|$token|g"

      echo "$envoy_config" > "/etc/envoy.yaml"
      chown root:root /etc/envoy.yaml
      chmod 644 /etc/envoy.yaml
      echo "envoy configuration saved to /etc/envoy.yaml"
      return 0
    }

    # Main execution flow
    if ! wait_for_slurm_api; then
        exit 1
    fi

    if ! populate_envoy_config "$slurm_impersonation_token"; then
        exit 1
    fi

    if ! install_envoy; then
        exit 1
    fi

    echo "Envoy pre Script finished successfully. Ready to start envoy."
  EOT

  envoy_systemd_content = <<-EOT
    ###############################################################################
    # wait readiness of slurmand start envoy
    ###############################################################################

    [Unit]
    Description=Wait for Slurm REST API and Start Envoy
    After=network.target
    Wants=network.target

    [Service]
    Type=oneshot
    RemainAfterExit=no
    TimeoutSec=3000s
    RestartSec=10s
    Restart=on-failure
    WorkingDirectory=/etc
    ExecStartPre=/opt/envoy-pre.sh
    ExecStart=/bin/envoy -c /etc/envoy.yaml
    StandardOutput=journal
    StandardError=journal

    [Install]
    WantedBy=multi-user.target
  EOT

  startup_script_gateway_runner_content = <<-EOT
    #!/bin/bash

    set -e

    # Create envoy pre script file
    cat <<'EOF_ENVOY_PRE' > /opt/envoy-pre.sh
    ${local.envoy_pre_script_content}
    EOF_ENVOY_PRE
    chmod 755 /opt/envoy-pre.sh
    echo "Created /opt/envoy-pre.sh"

    # Create envoy-wait service file
    cat <<'EOF_ENVOY_SYSTEMD' > /etc/systemd/system/envoy-wait.service
    ${local.envoy_systemd_content}
    EOF_ENVOY_SYSTEMD

    chmod 755 /etc/systemd/system/envoy-wait.service
    echo "Created /etc/systemd/system/envoy-wait.service"

    # Enable and start the envoy-wait service
    echo "Starting envoy-wait service"
    set +e # Disable exit on error, make sure won't fail the startup scripts
    systemctl daemon-reload # Reload systemd to read new files
    systemctl enable envoy-wait # Enable the service to start on boot
    systemctl start envoy-wait > /dev/null 2>&1 & # Start the service in the background
    set -e # Re-Enable exit on error

    # Check logs by running `journalctl -u envoy-wait.service`
    echo "Envoy startup is now managed by the envoy-wait service."
  EOT

  controller_startup_script_gateway_runner = [
    {
      type        = "shell"
      destination = "install_gateway.sh"
      content     = local.startup_script_gateway_runner_content
  }]

  controller_startup_script_runner = concat(local.controller_startup_script_gateway_runner, var.controller.startup_script_runner)
}

module "network" {
  source          = "./modules/embedded/modules/network/vpc"
  deployment_name = var.deployment_name
  labels          = var.labels
  project_id      = var.project_id
  region          = var.region
}

module "debug_nodeset" {
  source                  = "./modules/embedded/community/modules/compute/schedmd-slurm-gcp-v6-nodeset"
  allow_automatic_updates = false
  labels                  = var.labels
  machine_type            = "n2-standard-4"
  name                    = "debug_nodeset"
  node_count_dynamic_max  = 4
  project_id              = var.project_id
  region                  = var.region
  subnetwork_self_link    = module.network.subnetwork_self_link
  zone                    = var.zone
}

module "debug_partition" {
  source         = "./modules/embedded/community/modules/compute/schedmd-slurm-gcp-v6-partition"
  exclusive      = false
  is_default     = true
  nodeset        = flatten([module.debug_nodeset.nodeset])
  partition_name = "debug"
}

module "slurm_controller" {
  source                       = "./modules/embedded/community/modules/scheduler/schedmd-slurm-gcp-v6-controller"
  deployment_name              = var.deployment_name
  enable_controller_public_ips = true
  labels                       = var.labels
  nodeset                      = flatten([module.debug_partition.nodeset])
  nodeset_dyn                  = flatten([module.debug_partition.nodeset_dyn])
  nodeset_tpu                  = flatten([module.debug_partition.nodeset_tpu])
  partitions                   = flatten([module.debug_partition.partitions])
  project_id                   = var.project_id
  region                       = var.region
  subnetwork_self_link         = module.network.subnetwork_self_link
  zone                         = var.zone
}
