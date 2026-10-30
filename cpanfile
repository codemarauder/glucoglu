# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Nishant Sharma <nishant@hopbox.in>
requires 'Mojolicious', '>= 9.48';    # 9.48 fixes CVE-2026-15747 (CSRF token / BREACH)
requires 'Mojo::Pg',    '>= 4.18';
requires 'DBD::Pg',     '>= 3.15.0';
requires 'IO::Socket::SSL', '>= 2.079';  # TLS for hypnotoad and STARTTLS for mail
