# Legacy PowerPoint conversion service

Not deployed. The iPad client posts raw `.ppt` bytes to `POST /convert` with
`Content-Type: application/vnd.ms-powerpoint` and its Supabase Bearer access
token. A verified user receives HTTP 200 `application/pdf`; no source URL/path
input, persistent storage or service-role key is accepted. Input limit is 80 MiB,
output 160 MiB, two concurrent jobs, upload timeout 30 s and conversion 120 s.
The client caches the returned PDF as a separate shared Material.

Set `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY`. Authorization is verified against
the configured project's `/auth/v1/user`; redirects are rejected. HTTPS must be
terminated by the hosting reverse proxy. Set its body limit to 80 MiB, response
timeout above 150 s, request/connection rate limits, and do not log Authorization.

Each conversion uses a temporary profile, disables macros, and runs LibreOffice
inside bubblewrap with private user/PID/network namespaces and a read-only root.
Only the job folder is writable. No subprocess shell is used and its environment
excludes bearer tokens/server configuration. Unsupported sandbox hosts fail closed.
The host must allow unprivileged user namespaces and the required namespace syscalls;
validate the hosting seccomp/AppArmor profile rather than running privileged or
turning off the sandbox. Run the image as its non-root user with a read-only root,
1 GiB `/tmp` tmpfs, dropped capabilities, no-new-privileges, 2 CPUs, 2 GiB memory
and a PID limit (e.g. 128). The gateway retains outbound HTTPS for Supabase auth;
the LibreOffice process has no network.

Build using `docker build -t bandal-ppt-converter backend/ppt-converter`.
`compose.yaml` supplies the resource limits and binds only localhost for an HTTPS
reverse proxy. Default Docker seccomp or host AppArmor may reject bubblewrap's
namespace operations; establish a least-privilege host-specific policy and verify
the sandbox before enabling this service. Do not remove namespace isolation or
run the container privileged as a workaround.
Before exposure, test a real Hangul/font-heavy `.ppt`, malformed OLE, timeout,
parallel requests and external-link isolation on the actual host. This environment
has no LibreOffice, so real conversion and container sandbox execution remain
deployment gates. Unit tests exercise request validation/auth and the subprocess
contract; they do not claim a real document conversion has passed.
