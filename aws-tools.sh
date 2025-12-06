# aws-tools.sh
# Portable helper functions for AWS CLI (bash + zsh)

# Make AWS CLI output predictable
export AWS_PAGER=""
export AWS_CLI_AUTO_PROMPT=off

# Sometimes the easy way is the hard way, zsh globs
aws_profile_sanitize() {
  if [ -n "${AWS_PROFILE:-}" ]; then
    local original="$AWS_PROFILE"

    # If it starts with '||', strip that prefix
    case "$AWS_PROFILE" in
      '||'*) AWS_PROFILE="${AWS_PROFILE#'||'}" ;;
    esac

    export AWS_PROFILE

    if [ "$original" != "$AWS_PROFILE" ]; then
      echo "aws_profile_sanitize: fixed AWS_PROFILE from '$original' to '$AWS_PROFILE'" >&2
    fi
  fi
}

# ---------------------------------------------------------------------------
# awsbase
#   Detect or select a "base" SSO/IAM Identity Center profile.
#   Prints the profile name to stdout.
# ---------------------------------------------------------------------------
awsbase() {
    local profiles=()
    local p sso_sess sso_url
    local sso_profiles=()

    while IFS= read -r p; do
        [ -z "$p" ] && continue
        sso_sess=$(aws configure get sso_session --profile "$p" 2>/dev/null || true)
        sso_url=$(aws configure get sso_start_url --profile "$p" 2>/dev/null || true)
        if [ -n "$sso_sess" ] || [ -n "$sso_url" ]; then
            sso_profiles+=("$p")
        fi
    done < <(aws configure list-profiles)

    if [ "${#sso_profiles[@]}" -eq 0 ]; then
        echo "No SSO/IAM Identity Center profiles found." >&2
        return 1
    fi

    if [ "${#sso_profiles[@]}" -eq 1 ]; then
        echo "${sso_profiles[0]}"
        return 0
    fi

    echo "Select base SSO profile:"
    local i choice idx
    for (( i=0; i<${#sso_profiles[@]}; i++ )); do
        idx=$((i+1))
        printf "  %2d) %s\n" "$idx" "${sso_profiles[$i]}"
    done

    printf "Enter number: "
    IFS= read -r choice

    case "$choice" in
        ''|*[!0-9]*)
            echo "Invalid selection." >&2
            return 1
            ;;
    esac

    local index=$((choice-1))
    if [ "$index" -lt 0 ] || [ "$index" -ge "${#sso_profiles[@]}" ]; then
        echo "Invalid selection." >&2
        return 1
    fi

    echo "${sso_profiles[$index]}"
}

# ---------------------------------------------------------------------------
# aws_sso_token
#   Get the current SSO access token for a given profile.
#   Usage: TOKEN=$(aws_sso_token my-sso-profile)
# ---------------------------------------------------------------------------
aws_sso_token() {
    local profile="${1:-${AWS_SSO_BASE_PROFILE:-}}"
    local config_file="${HOME}/.aws/config"

    if [ -z "$profile" ]; then
        profile=$(awsbase) || return 1
    fi

    local start_url
    start_url=$(aws configure get sso_start_url --profile "$profile" 2>/dev/null || true)

    if [ -z "$start_url" ]; then
        local sess
        sess=$(aws configure get sso_session --profile "$profile" 2>/dev/null || true)
        if [ -n "$sess" ] && [ -f "$config_file" ]; then
            start_url=$(
                sed -n "/^\[sso-session ${sess}\]/,/^\[/p" "$config_file" \
                | grep -m1 'sso_start_url' \
                | cut -d'=' -f2- \
                | xargs
            )
        fi
    fi

    local cache_dir="${HOME}/.aws/sso/cache"
    if [ ! -d "$cache_dir" ]; then
        echo "No SSO cache dir at $cache_dir. Run 'aws sso login --profile $profile' first." >&2
        return 1
    fi

    local file=""
    if [ -n "$start_url" ]; then
        file=$(grep -l "\"startUrl\": \"$start_url\"" "$cache_dir"/*.json 2>/dev/null | sort | tail -n 1)
    fi

    if [ -z "$file" ]; then
        file=$(ls -1t "$cache_dir"/*.json 2>/dev/null | head -n 1)
    fi

    if [ -z "$file" ]; then
        echo "No SSO cache files found. Try 'aws sso login --profile $profile' again." >&2
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        echo "This helper requires 'jq' to be installed." >&2
        return 1
    fi

    jq -r '.accessToken' "$file"
}

# ---------------------------------------------------------------------------
# awssyncprofiles
#   Generate [profile ...] stanzas for all SSO accounts/roles.
#   Usage: awssyncprofiles base-profile > ~/.aws/sso-generated-profiles
# ---------------------------------------------------------------------------
awssyncprofiles() {
    local base="${1:-${AWS_SSO_BASE_PROFILE:-}}"
    local config_file="${HOME}/.aws/config"

    if [ -z "$base" ]; then
        base=$(awsbase) || return 1
    fi

    local sso_region sso_start_url sso_sess
    sso_region=$(aws configure get sso_region --profile "$base" 2>/dev/null || true)
    sso_start_url=$(aws configure get sso_start_url --profile "$base" 2>/dev/null || true)
    sso_sess=$(aws configure get sso_session --profile "$base" 2>/dev/null || true)

    if [ -n "$sso_sess" ] && [ -f "$config_file" ]; then
        if [ -z "$sso_region" ]; then
            sso_region=$(
                sed -n "/^\[sso-session ${sso_sess}\]/,/^\[/p" "$config_file" \
                | grep -m1 'sso_region' \
                | cut -d'=' -f2- \
                | xargs
            )
        fi
        if [ -z "$sso_start_url" ]; then
            sso_start_url=$(
                sed -n "/^\[sso-session ${sso_sess}\]/,/^\[/p" "$config_file" \
                | grep -m1 'sso_start_url' \
                | cut -d'=' -f2- \
                | xargs
            )
        fi
    fi

    if [ -z "$sso_region" ] || [ -z "$sso_start_url" ]; then
        echo "Could not resolve SSO region/start URL from base profile '$base'." >&2
        return 1
    fi

    local default_region
    default_region=$(aws configure get region --profile "$base" 2>/dev/null || true)
    [ -z "$default_region" ] && default_region="$sso_region"

    local token
    token=$(aws_sso_token "$base") || return 1

    if ! command -v jq >/dev/null 2>&1; then
        echo "This function requires 'jq' to be installed." >&2
        return 1
    fi

    local accounts_json
    accounts_json=$(aws sso list-accounts \
        --region "$sso_region" \
        --access-token "$token")

    echo "# Generated by awssyncprofiles using base profile '$base' on $(date)"

    echo "$accounts_json" | jq -r '.accountList[] | [.accountId, .accountName] | @tsv' | \
    while IFS=$'\t' read -r acc_id acc_name; do
        local safe_name roles_json
        safe_name=$(echo "$acc_name" | tr ' ' '-' | tr '[:upper:]' '[:lower:]' | tr -cd 'a-zA-Z0-9-_')

        roles_json=$(aws sso list-account-roles \
            --region "$sso_region" \
            --access-token "$token" \
            --account-id "$acc_id" \
            | tr -d '\r' \
            | sed '/^[[:space:]]*$/d')

        echo "$roles_json" | jq -r '.roleList[].roleName' | while IFS= read -r role; do
            [ -z "$role" ] && continue
            local profile_name
            profile_name="${safe_name}-${role}"

            echo
            echo "[profile ${profile_name}]"
            if [ -n "$sso_sess" ]; then
                echo "sso_session = ${sso_sess}"
            else
                echo "sso_start_url = ${sso_start_url}"
                echo "sso_region = ${sso_region}"
            fi
            echo "sso_account_id = ${acc_id}"
            echo "sso_role_name = ${role}"
            echo "region = ${default_region}"
            echo "output = json"
        done
    done
}

# ---------------------------------------------------------------------------
# awsjump
#   2-step profile picker: account (prefix) -> role (suffix).
#   Assumes profile names like: account-prefix-with-hyphens-RoleName
# ---------------------------------------------------------------------------
awsjump() {
    local target="$1"
    local profiles=()
    local p

    while IFS= read -r p; do
        [ -n "$p" ] && profiles+=("$p")
    done < <(aws configure list-profiles)

    local count=${#profiles[@]}
    if [ "$count" -eq 0 ]; then
        echo "No AWS profiles found."
        return 1
    fi

    # Fast path: explicit profile name
    if [ -n "$target" ]; then
        for p in "${profiles[@]}"; do
            if [ "$p" = "$target" ]; then
                export AWS_PROFILE="$p"
                aws_profile_sanitize
                echo "AWS_PROFILE set to '$AWS_PROFILE'."
                return 0
            fi
        done
        echo "Profile '$target' not found."
        printf 'Available profiles:\n  %s\n' "${profiles[@]}"
        return 1
    fi

    # Build unique account prefixes (everything before last '-')
    local acct_prefixes=()
    local prefix seen existing

    for p in "${profiles[@]}"; do
        case "$p" in
            *-*)
                prefix=${p%-*}
                ;;
            *)
                continue
                ;;
        esac

        [ -z "$prefix" ] && continue

        seen=0
        for existing in "${acct_prefixes[@]}"; do
            if [ "$existing" = "$prefix" ]; then
                seen=1
                break
            fi
        done
        [ "$seen" -eq 0 ] && acct_prefixes+=("$prefix")
    done

    if [ "${#acct_prefixes[@]}" -eq 0 ]; then
        echo "No usable prefix-style (account-role) profiles found."
        return 1
    fi

    # Sort prefixes
    IFS=$'\n' acct_prefixes=($(printf '%s\n' "${acct_prefixes[@]}" | sort))
    unset IFS

    echo "Select AWS account:"
    local i choice idx
    for (( i=0; i<${#acct_prefixes[@]}; i++ )); do
        idx=$((i+1))
        printf "  %2d) %s\n" "$idx" "${acct_prefixes[$i]}"
    done

    printf "Enter account number: "
    IFS= read -r choice

    case "$choice" in
        ''|*[!0-9]*)
            echo "Invalid account selection."
            return 1
            ;;
    esac

    local choice_index=$((choice-1))
    if [ "$choice_index" -lt 0 ] || [ "$choice_index" -ge "${#acct_prefixes[@]}" ]; then
        echo "Invalid account selection."
        return 1
    fi

    local chosen_prefix="${acct_prefixes[$choice_index]}"

    # Collect roles for chosen prefix
    local roles=()
    local role_profiles=()
    local role

    for p in "${profiles[@]}"; do
        case "$p" in
            "${chosen_prefix}-"*)
                role=${p#${chosen_prefix}-}
                [ -z "$role" ] && continue
                roles+=("$role")
                role_profiles+=("$p")
                ;;
        esac
    done

    if [ "${#roles[@]}" -eq 0 ]; then
        echo "No roles found for account prefix '$chosen_prefix'."
        return 1
    fi

    # Sort roles while preserving mapping
    local lines=()
    for (( i=0; i<${#roles[@]}; i++ )); do
        lines+=("${roles[$i]}|||${role_profiles[$i]}")
    done

    local sorted
    sorted=$(printf '%s\n' "${lines[@]}" | sort)

    local sorted_roles=()
    local sorted_profiles=()
    local line r prof

    while IFS='|||' read -r r prof; do
        [ -z "$r" ] && continue
        sorted_roles+=("$r")
        sorted_profiles+=("$prof")
    done <<< "$sorted"

    classify_role() {
        case "$1" in
            *Admin*|*Administrator*|*PowerUser* )
                echo "admin"
                ;;
            *ReadOnly*|*View*|*Viewer* )
                echo "read-only"
                ;;
            *Billing* )
                echo "billing"
                ;;
            *Security* )
                echo "security"
                ;;
            *Dev*|*Developer* )
                echo "developer"
                ;;
            *Ops*|*Operator* )
                echo "ops"
                ;;
            * )
                echo "custom"
                ;;
        esac
    }

    echo "Select role for '${chosen_prefix}':"
    local access
    for (( i=0; i<${#sorted_roles[@]}; i++ )); do
        idx=$((i+1))
        access=$(classify_role "${sorted_roles[$i]}")
        printf "  %2d) %s  (%s)\n" "$idx" "${sorted_roles[$i]}" "$access"
    done

    printf "Enter role number: "
    IFS= read -r choice

    case "$choice" in
        ''|*[!0-9]*)
            echo "Invalid role selection."
            return 1
            ;;
    esac

    choice_index=$((choice-1))
    if [ "$choice_index" -lt 0 ] || [ "$choice_index" -ge "${#sorted_roles[@]}" ]; then
        echo "Invalid role selection."
        return 1
    fi

    local chosen_profile="${sorted_profiles[$choice_index]}"
    export AWS_PROFILE="$chosen_profile"
    aws_profile_sanitize
    echo "AWS_PROFILE set to '$AWS_PROFILE'."
}

# ---------------------------------------------------------------------------
# awsfix
#   Ensure current profile has valid creds; run aws sso login if expired.
# ---------------------------------------------------------------------------
awsfix() {
    local profile="${AWS_PROFILE:-}"

    if [ -z "$profile" ]; then
        echo "AWS_PROFILE is not set; invoking awsjump."
        awsjump || return 1
        profile="$AWS_PROFILE"
        [ -z "$profile" ] && return 1
    fi

    echo "Checking credentials for profile '$profile'..."

    if aws sts get-caller-identity --profile "$profile" >/dev/null 2>&1; then
        echo "AWS creds for '$profile' are still valid."
        return 0
    fi

    echo "Credentials for '$profile' appear to be expired or invalid."
    printf "Run 'aws sso login --profile %s' now? [y/N]: " "$profile"
    local answer
    IFS= read -r answer

    case "$answer" in
        [yY]*)
            aws sso login --profile "$profile" || {
                echo "aws sso login failed." >&2
                return 1
            }
            if aws sts get-caller-identity --profile "$profile" >/dev/null 2>&1; then
                echo "SSO login successful."
                aws sts get-caller-identity --profile "$profile"
                return 0
            else
                echo "Creds still not valid after login." >&2
                return 1
            fi
            ;;
        *)
            echo "Aborted; credentials remain invalid."
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# awswhere
#   Show current identity and profile/region at a glance.
# ---------------------------------------------------------------------------
awswhere() {
    local profile="${1:-${AWS_PROFILE:-}}"
    if [ -z "$profile" ]; then
        echo "No profile specified and AWS_PROFILE is not set." >&2
        return 1
    fi

    local region
    region=$(aws configure get region --profile "$profile" 2>/dev/null || true)
    [ -z "$region" ] && region="${AWS_REGION:-${AWS_DEFAULT_REGION:-unknown}}"

    local ident
    if ! ident=$(aws sts get-caller-identity --profile "$profile" 2>/dev/null); then
        echo "Failed to get caller identity for profile '$profile'." >&2
        return 1
    fi

    if command -v jq >/dev/null 2>&1; then
        local account arn user
        account=$(echo "$ident" | jq -r '.Account')
        arn=$(echo "$ident" | jq -r '.Arn')
        user=$(echo "$ident" | jq -r '.UserId')
        echo "Profile : $profile"
        echo "Region  : $region"
        echo "Account : $account"
        echo "UserId  : $user"
        echo "ARN     : $arn"
    else
        echo "Profile: $profile"
        echo "Region : $region"
        echo "Raw sts get-caller-identity output:"
        echo "$ident"
    fi
}

# ---------------------------------------------------------------------------
# awsprofiles
#   Show all profiles with SSO account/role metadata.
# ---------------------------------------------------------------------------
awsprofiles() {
    local profiles=()
    local p
    while IFS= read -r p; do
        [ -n "$p" ] && profiles+=("$p")
    done < <(aws configure list-profiles)

    if [ "${#profiles[@]}" -eq 0 ]; then
        echo "No AWS profiles found."
        return 0
    fi

    printf "%-30s %-14s %-30s\n" "PROFILE" "ACCOUNT" "ROLE"
    printf "%-30s %-14s %-30s\n" "-------" "-------" "----"

    local acc role
    for p in "${profiles[@]}"; do
        acc=$(aws configure get sso_account_id --profile "$p" 2>/dev/null || true)
        role=$(aws configure get sso_role_name --profile "$p" 2>/dev/null || true)
        printf "%-30s %-14s %-30s\n" "$p" "${acc:-"-"}" "${role:-"-"}"
    done
}

# ---------------------------------------------------------------------------
# awsclear
#   Clear AWS-related environment variables.
# ---------------------------------------------------------------------------
awsclear() {
    unset AWS_PROFILE AWS_DEFAULT_PROFILE
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
    unset AWS_REGION AWS_DEFAULT_REGION
    echo "Cleared AWS_* environment variables."
}
