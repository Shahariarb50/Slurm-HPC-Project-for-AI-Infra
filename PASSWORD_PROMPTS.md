# Password Prompt Checklist

This list explains the password prompts used by the Slurm setup scripts. Store passwords in a password manager; do not add real passwords to scripts, README files, or shared links.

## Password types

| Password type | Used for |
|---|---|
| Controller Linux sudo password | Administrative commands on controller |
| Login-node Linux sudo password | Administrative commands on login node |
| Worker Linux sudo password | Administrative commands on worker node |
| LDAP admin password | Managing LDAP users, groups, and bindings |
| Database password | Slurm accounting database connection |
| New LDAP user password | SSH/login password for the user being created |
| Controller SSH password | Copying the MUNGE key automatically from controller to login node |

## Script-by-script prompts

| Script | Password prompt | Which password to enter |
|---|---|---|
| `setup-slurm-web-controller-dynamic.sh` | `Enter Database Password` | A new strong database password chosen during controller setup |
|  | `Enter LDAP Admin Password` | LDAP administrator password chosen during controller setup |
|  | `Enter password for default user` | Password for the initial normal LDAP user |
|  | `Enter password for Slurm admin` | Password for the initial LDAP/Slurm administrator user |
| `setup-login-node-dynamic.sh` | Initial `sudo` prompt | Login-node Linux sudo password |
|  | `LDAP bind password` | LDAP administrator/bind password |
|  | `Controller SSH and sudo password` | Controller Linux account password; only when automatic MUNGE-key copy is enabled |
| `setup-worker-node-gpu-dynamic.sh` | Initial `sudo` prompt | Worker Linux sudo password |
| `setup_ldap_identity_client_dynamic.sh` | Initial `sudo` prompt | The local node's Linux sudo password |
|  | `LDAP bind password` | LDAP administrator/bind password |
| `setup_shared_home_controller_dynamic.sh` | Initial `sudo` prompt | Controller Linux sudo password |
| `setup_shared_home_login_dynamic.sh` | Initial `sudo` prompt | Login-node Linux sudo password |
| `setup_shared_home_worker_dynamic.sh` | Initial `sudo` prompt | Worker Linux sudo password |
| `create_ldap_slurm_user_dynamic.sh` | Initial `sudo` prompt | Controller Linux sudo password |
|  | `LDAP admin password` | LDAP administrator password |
|  | `Password for <new-user>` | New user's own SSH/LDAP password |
| `manage_ldap_slurm_users_groups_dynamic.sh` | Initial `sudo` prompt | Controller Linux sudo password |
|  | `LDAP admin password` | LDAP administrator password |
|  | `New password for <user>` | Only when selecting the password-edit option |
| `slurm_superadmin_menu.sh` | Initial `sudo` prompt | Controller Super Admin's Linux sudo password |
| `submit_slurm_job_dynamic.sh` | None | Normal user submits a job; no administrator password is required |

## Important notes

- `sudo` asks for the password of the currently logged-in Linux account, not the LDAP administrator password.
- The LDAP admin password is used by scripts that create, edit, delete, or look up LDAP identities.
- A normal user should know only their own login password. They must never receive the LDAP admin password, MUNGE key, or database password.
- Change default or reused passwords before production use, and keep controller SSH, LDAP admin, database, and user passwords separate.
