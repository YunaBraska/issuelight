FROM debian@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc AS build

ARG NAGIOS_VERSION=4.5.14
ARG NAGIOS_SHA256=dce59f306577789c56d2748471d4c3856ecba8572d6b0811cf79f9de2f9afabb

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        autoconf \
        automake \
        build-essential \
        ca-certificates \
        curl \
        gettext \
        libgd-dev \
        libssl-dev \
        unzip \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system nagios \
    && useradd --system --gid nagios --home-dir /usr/local/nagios --shell /usr/sbin/nologin nagios

WORKDIR /tmp/nagios-build
RUN curl --fail --location --silent --show-error \
        --output nagios.tar.gz \
        "https://github.com/NagiosEnterprises/nagioscore/releases/download/nagios-${NAGIOS_VERSION}/nagios-${NAGIOS_VERSION}.tar.gz" \
    && printf '%s  %s\n' "$NAGIOS_SHA256" nagios.tar.gz | sha256sum --check --strict \
    && tar --extract --gzip --file nagios.tar.gz --strip-components=1 \
    && ./configure \
        --with-command-group=nagios \
        --with-httpd-conf=/etc/apache2/conf-enabled \
        --with-nagios-group=nagios \
        --with-nagios-user=nagios \
    && make --jobs="$(getconf _NPROCESSORS_ONLN)" all \
    && make install

FROM debian@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        apache2 \
        apache2-utils \
        ca-certificates \
        libgd3 \
        libssl3 \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system nagios \
    && useradd --system --gid nagios --home-dir /usr/local/nagios --shell /usr/sbin/nologin nagios \
    && usermod --append --groups nagios www-data \
    && a2enmod cgi rewrite

COPY --from=build /usr/local/nagios /usr/local/nagios
COPY apache-nagios.conf /etc/apache2/conf-enabled/nagios.conf
COPY nagios.cfg /usr/local/nagios/etc/nagios.cfg
COPY cgi.cfg /usr/local/nagios/etc/cgi.cfg
COPY objects.cfg /usr/local/nagios/etc/objects.cfg
COPY resource.cfg /usr/local/nagios/etc/resource.cfg
COPY entrypoint.sh /usr/local/bin/issuelight-nagios-entrypoint

RUN mkdir --parents \
        /run/apache2 \
        /usr/local/nagios/var/archives \
        /usr/local/nagios/var/rw \
        /usr/local/nagios/var/spool/checkresults \
    && chown --recursive nagios:nagios /usr/local/nagios/var \
    && chmod 2775 /usr/local/nagios/var/rw /usr/local/nagios/var/spool/checkresults \
    && chmod 0755 /usr/local/bin/issuelight-nagios-entrypoint

EXPOSE 80
ENTRYPOINT ["/usr/local/bin/issuelight-nagios-entrypoint"]
