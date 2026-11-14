FROM alpine:3.22@sha256:49340b346798875b5592e5d420241f2f9cfba5f47e62ebb1446a1b34734e898f

RUN apk add --no-cache darkhttpd openssh-server \
    && adduser -D -s /bin/sh operator \
    && printf '%s\n' 'operator:disabled-password' | chpasswd \
    && ssh-keygen -A \
    && mkdir -p /run/sshd /srv/http /run/issuelight \
    && printf '%s\n' 'IssueLight SSH tunnel fixture' > /srv/http/index.html \
    && sed -i 's/^AllowTcpForwarding .*/AllowTcpForwarding yes/' /etc/ssh/sshd_config \
    && printf '%s\n' \
        'PasswordAuthentication no' \
        'KbdInteractiveAuthentication no' \
        'PermitRootLogin no' \
        'GatewayPorts no' \
        'PermitOpen 127.0.0.1:8080' \
        >> /etc/ssh/sshd_config

COPY entrypoint.sh /usr/local/bin/issuelight-ssh-entrypoint
RUN chmod 755 /usr/local/bin/issuelight-ssh-entrypoint

EXPOSE 22
ENTRYPOINT ["/usr/local/bin/issuelight-ssh-entrypoint"]
