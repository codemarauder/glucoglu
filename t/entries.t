use Mojo::Base -strict, -signatures;
use Digest::SHA 'sha1_hex';

use Test::More;
plan skip_all => 'set GLUCOGLU_DB_DSN to a throwaway Postgres DSN (e.g. postgresql://glucoglu:pass@localhost/glucoglu_test)'
  unless $ENV{GLUCOGLU_DB_DSN};

use Test::Mojo;
my $t   = Test::Mojo->new('Glucoglu');
my $db  = $t->app->pg->db;
my $one = sub ($sql, @args) { $db->query($sql, @args)->array->[0] };
$db->query(
  'DELETE FROM mail_log; DELETE FROM login_tokens; DELETE FROM payload_log; DELETE FROM readings; DELETE FROM users; DELETE FROM invites');
my $uid = $db->query("INSERT INTO users (email, api_token) VALUES ('a\@b.co', 'tok123') RETURNING id")->array->[0];

subtest 'single entry ingest' => sub {
  $t->post_ok('/api/v1/entries?token=tok123', json => {type => 'sgv', date => 1730000000000, sgv => 120})
    ->status_is(200)->json_is('/inserted' => 1)->json_is('/rejected' => 0);
  is $one->('SELECT mg_dl FROM readings'), 120, 'value stored as mg/dL';
  is $one->('SELECT extract(epoch FROM ts)::bigint FROM readings'), 1730000000, 'ms epoch stored as UTC seconds';
  is $one->("SELECT raw->>'sgv' FROM readings"), 120, 'raw payload kept (O7 audit trail)';
}, $one;

subtest 'duplicates are ignored' => sub {
  $t->post_ok('/api/v1/entries?token=tok123', json => {type => 'sgv', date => 1730000000000, sgv => 121})
    ->status_is(200)->json_is('/inserted' => 0);
  $t->post_ok('/api/v1/entries?token=tok123',
      json => [{type => 'sgv', date => 1730000000000, sgv => 121}, {type => 'sgv', date => 1730000900000, sgv => 122}])
    ->status_is(200)->json_is('/inserted' => 1);
  is $one->('SELECT count(*) FROM readings'), 2, 'overlapping scans never count twice';
}, $one;

subtest 'unit rule (D11)' => sub {
  $t->post_ok('/api/v1/entries?token=tok123', json => {type => 'sgv', date => 1730001000000, sgv => 7.8})
    ->status_is(200)->json_is('/inserted' => 1);
  ok abs($one->('SELECT mg_dl FROM readings WHERE ts = to_timestamp(1730001000)') - 7.8 * 18.018) < 0.01,
    'mmol/L converted to mg/dL';
  $t->post_ok('/api/v1/entries?token=tok123', json => {type => 'sgv', date => 1730002000000, sgv => 30})
    ->status_is(200)->json_is('/inserted' => 0)->json_is('/rejected' => 1);
  is $one->('SELECT count(*) FROM readings'), 3, 'value between both unit ranges rejected';
}, $one;

subtest 'auth' => sub {
  $t->post_ok('/api/v1/entries?token=WRONG', json => {sgv => 100})->status_is(401);
  $t->post_ok('/api/v1/entries', json => {sgv => 100})->status_is(401);
  $t->post_ok('/api/v1/entries', {Authorization => 'Bearer tok123'}, json => {sgv => 100, date => 1730003000000})
    ->status_is(200)->json_is('/inserted' => 1);
}, $one;

subtest 'unreadable bodies are captured (O7)' => sub {
  $t->post_ok('/api/v1/entries?token=tok123', {Authorization => 'Bearer tok123'}, json => {foo => 1})
    ->status_is(200)->json_is('/inserted' => 0);
  is $one->('SELECT count(*) FROM payload_log'), 1, 'unknown payload kept for field-name verification';
  like $one->('SELECT raw->>\'foo\' FROM payload_log'), qr/^1$/, 'captured verbatim';
}, $one;

subtest 'Nightscout V3 handshake (Juggluco test V3)' => sub {
  $t->get_ok('/api/v2/authorization/request/tok123')->status_is(200)
    ->json_is('/token' => 'tok123')->json_like('/exp' => qr/^\d+$/);
  $t->get_ok('/api/v2/authorization/request/WRONG')->status_is(401);
  $t->post_ok('/api/v3/entries', {Authorization => 'Bearer tok123'},
      json => [{type => 'sgv', date => 1730004000000, sgv => 118}])
    ->status_is(200)->json_is('/inserted' => 1);
  is $one->('SELECT count(*) FROM readings'), 5, 'v3 upload stored';
}, $one;

subtest 'Nightscout V1 api-secret header (Juggluco default)' => sub {
  $t->post_ok('/api/v1/entries', {'api-secret' => sha1_hex('tok123')},
      json => [{type => 'sgv', date => 1730005000000, sgv => 117}])
    ->status_is(200)->json_is('/inserted' => 1);
  $t->post_ok('/api/v1/entries', {'api-secret' => sha1_hex('WRONG')}, json => {sgv => 1})
    ->status_is(401);
  is $one->('SELECT count(*) FROM readings'), 6, 'v1 upload stored';
}, $one;

done_testing();