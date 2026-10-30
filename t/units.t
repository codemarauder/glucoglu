# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Nishant Sharma <nishant@hopbox.in>
use Mojo::Base -strict, -signatures;

use Test::More;
use Glucoglu::Units 'to_mgdl';

# mmol/L range 2.2-27.8: converted
ok abs(to_mgdl(2.2)  - 2.2  * 18.018) < 1e-9, '2.2 mmol/L is the lower edge';
ok abs(to_mgdl(27.8) - 27.8 * 18.018) < 1e-9, '27.8 mmol/L is the upper edge';

# mg/dL range 40-500: kept
is to_mgdl(40),  40,  '40 mg/dL is the lower edge';
is to_mgdl(120), 120, 'normal mg/dL value kept';
is to_mgdl(500), 500, '500 mg/dL is the upper edge';

# everything else: rejected
is to_mgdl($_), undef, "rejected: $_" for 0, -5, 2.1, 30, 501, 'abc', 'Inf', '-Inf', 'NaN', '';
is to_mgdl(undef), undef, 'rejected: undef';
is to_mgdl([]),    undef, 'rejected: reference';

done_testing;
