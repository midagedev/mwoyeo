#!/usr/bin/env python3
"""App Store Connect from the command line, for Mwoyeo's Mac App Store record. Standard library and openssl only.

  asc.py status          the app, its versions and their state, the builds and their processing state
  asc.py apply [--dry]   writes docs/app-store/metadata.md and metadata/*.md to the version being prepared: the version
                         string (newest v* tag), the 12 locales (name, subtitle, privacy URL; description, keywords,
                         promotional text, support and marketing URLs), categories, copyright, and the newest valid build
  asc.py shots [--dry]   the Mac screenshots of every locale (APP_DESKTOP set of the version being prepared): Korean gets
                         tools/app-store/screenshots/out/ko, every other locale out/en (compose.sh makes them); the set's
                         screenshots are replaced, in file order
  asc.py previews [--dry]  the Mac app preview of every locale (DESKTOP set of the version being prepared): Korean gets
                         tools/app-store/previews/out/ko.mp4, every other locale out/en.mp4 (cut.sh makes them, with the poster
                         frame's time code in out/<lang>.poster); the set's previews are replaced

Key: ASC_KEY_ID (default J6C3DV9S7R), ASC_ISSUER_ID, ASC_KEY_FILE (default ~/.appstoreconnect/private_keys/AuthKey_<id>.p8).
What the API does not cover (App Privacy answers, price, review contact) is done in the web page."""
import base64, hashlib, importlib.util, json, os, shutil, subprocess, sys, time, urllib.error, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BUNDLE = 'dev.midagedev.mwoyeo.appstore'
API = 'https://api.appstoreconnect.apple.com'
# our metadata locale -> App Store Connect locale
LOCALES = {'ko': 'ko', 'en': 'en-US', 'de': 'de-DE', 'es': 'es-ES', 'fr': 'fr-FR', 'it': 'it', 'ja': 'ja', 'pt-BR': 'pt-BR',
           'ru': 'ru', 'uk': 'uk', 'zh-Hans': 'zh-Hans', 'zh-Hant': 'zh-Hant'}
PRIVACY = 'https://github.com/midagedev/mwoyeo/blob/main/docs/PRIVACY.md'
SUPPORT = 'https://github.com/midagedev/mwoyeo/issues'
MARKETING = 'https://github.com/midagedev/mwoyeo'
COPYRIGHT = '2026 Hyeoncheol Kim'
SHOTS = os.path.join(ROOT, 'tools/app-store/screenshots/out')
PREVIEWS = os.path.join(ROOT, 'tools/app-store/previews/out')


def b64(b):
    return base64.urlsafe_b64encode(b).rstrip(b'=').decode()


def der_to_raw(der):
    """An ECDSA DER signature (openssl's) as the 64-byte r||s a JWT carries."""
    def integer(i):
        assert der[i] == 0x02
        n = der[i + 1]
        return int.from_bytes(der[i + 2:i + 2 + n], 'big'), i + 2 + n
    r, i = integer(2)
    s, _ = integer(i)
    return r.to_bytes(32, 'big') + s.to_bytes(32, 'big')


def token():
    kid = os.environ.get('ASC_KEY_ID', 'J6C3DV9S7R')
    iss = os.environ.get('ASC_ISSUER_ID') or sys.exit('set ASC_ISSUER_ID')
    key = os.environ.get('ASC_KEY_FILE', os.path.expanduser(f'~/.appstoreconnect/private_keys/AuthKey_{kid}.p8'))
    now = int(time.time())
    head = b64(json.dumps({'alg': 'ES256', 'kid': kid, 'typ': 'JWT'}).encode())
    body = b64(json.dumps({'iss': iss, 'iat': now, 'exp': now + 900, 'aud': 'appstoreconnect-v1'}).encode())
    sig = subprocess.run(['openssl', 'dgst', '-sha256', '-sign', key], input=f'{head}.{body}'.encode(), capture_output=True, check=True).stdout
    return f'{head}.{body}.{b64(der_to_raw(sig))}'


TOKEN, TOKEN_AT = None, 0.0


def call(method, path, body=None):
    # A token lives 15 minutes; a run that waits on video processing outlives it (an upload of 12 previews stopped on a 401,
    # 2026-10-20), so a token older than 10 minutes is replaced.
    global TOKEN, TOKEN_AT
    if TOKEN is None or time.time() - TOKEN_AT > 600:
        TOKEN, TOKEN_AT = token(), time.time()
    req = urllib.request.Request(API + path, method=method, data=json.dumps(body).encode() if body else None,
                                 headers={'Authorization': f'Bearer {TOKEN}', 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req) as r:
            data = r.read()
            return json.loads(data) if data else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode()
        # A read that meets a server error is asked again (a poll of a preview's processing got one HTTP 500, 2026-10-20).
        if method == 'GET' and e.code >= 500 and getattr(call, 'retries', 0) < 3:
            call.retries = getattr(call, 'retries', 0) + 1
            time.sleep(10)
            try:
                return call(method, path, body)
            finally:
                call.retries -= 1
        sys.exit(f'{method} {path}: HTTP {e.code}\n{detail[:1500]}')


def put_chunk(url, method, headers, data):
    """One upload operation of an asset: its bytes to the URL Apple gave, with its headers (not the API: no prefix, no JSON, no token)."""
    req = urllib.request.Request(url, method=method, data=data, headers={h['name']: h['value'] for h in headers or []})
    try:
        with urllib.request.urlopen(req) as r:
            r.read()
    except urllib.error.HTTPError as e:
        sys.exit(f'{method} upload chunk: HTTP {e.code}\n{e.read().decode()[:1500]}')


def app():
    found = call('GET', f'/v1/apps?filter[bundleId]={BUNDLE}')['data']
    return found[0] if found else sys.exit(f'no app with bundle id {BUNDLE}')


def editable_version(app_id):
    vs = call('GET', f'/v1/apps/{app_id}/appStoreVersions?filter[platform]=MAC_OS')['data']
    for v in vs:
        if v['attributes']['appStoreState'] in ('PREPARE_FOR_SUBMISSION', 'DEVELOPER_REJECTED', 'REJECTED', 'METADATA_REJECTED'):
            return v
    sys.exit('no macOS version in an editable state')


def status():
    a = app()
    print('app', a['id'], a['attributes']['name'], a['attributes']['primaryLocale'])
    for v in call('GET', f'/v1/apps/{a["id"]}/appStoreVersions')['data']:
        print('version', v['attributes']['platform'], v['attributes']['versionString'], v['attributes']['appStoreState'])
    for b in call('GET', f'/v1/builds?filter[app]={a["id"]}&sort=-uploadedDate&limit=5')['data']:
        at = b['attributes']
        print('build', at['version'], at['processingState'], at['uploadedDate'], 'expired' if at.get('expired') else '')


def metadata():
    spec = importlib.util.spec_from_file_location('check', os.path.join(ROOT, 'tools/app-store/check-metadata.py'))
    check = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(check)
    out = {}
    files = [os.path.join(ROOT, 'docs/app-store/metadata.md')] + sorted(
        os.path.join(ROOT, 'docs/app-store/metadata', f) for f in os.listdir(os.path.join(ROOT, 'docs/app-store/metadata')))
    for f in files:
        for loc, fields in check.locales(f):
            out[loc] = {k: v[0] for k, v in fields.items()}
    return out


def upsert(kind, parent_rel, parent_type, parent_id, existing, locale, attrs, dry):
    cur = existing.get(locale)
    if dry:
        print(('update' if cur else 'create'), kind, locale, ', '.join(f'{k}={len(v)}' for k, v in attrs.items()))
        return
    if cur:
        call('PATCH', f'/v1/{kind}/{cur["id"]}', {'data': {'type': kind, 'id': cur['id'], 'attributes': attrs}})
    else:
        call('POST', f'/v1/{kind}', {'data': {'type': kind, 'attributes': {'locale': locale, **attrs},
                                              'relationships': {parent_rel: {'data': {'type': parent_type, 'id': parent_id}}}}})
    print('wrote', kind, locale)


def apply(dry):
    a = app()
    v = editable_version(a['id'])
    tag = subprocess.run(['git', '-C', ROOT, 'describe', '--tags', '--abbrev=0', '--match', 'v*'], capture_output=True, text=True, check=True).stdout.strip()
    version = tag.lstrip('v')
    meta = metadata()
    missing = set(LOCALES) - set(meta)
    if missing:
        sys.exit(f'metadata missing for {sorted(missing)}')

    if v['attributes']['versionString'] != version or v['attributes'].get('copyright') != COPYRIGHT:
        print(f'version {v["attributes"]["versionString"]} -> {version}, copyright')
        if not dry:
            call('PATCH', f'/v1/appStoreVersions/{v["id"]}', {'data': {'type': 'appStoreVersions', 'id': v['id'],
                 'attributes': {'versionString': version, 'copyright': COPYRIGHT}}})

    infos = call('GET', f'/v1/apps/{a["id"]}/appInfos')['data']
    info = next(i for i in infos if i['attributes'].get('appStoreState', i['attributes'].get('state')) not in ('READY_FOR_SALE', 'READY_FOR_DISTRIBUTION'))
    if not dry:
        call('PATCH', f'/v1/appInfos/{info["id"]}', {'data': {'type': 'appInfos', 'id': info['id'], 'relationships': {
            'primaryCategory': {'data': {'type': 'appCategories', 'id': 'PRODUCTIVITY'}},
            'secondaryCategory': {'data': {'type': 'appCategories', 'id': 'UTILITIES'}}}}})
    print('categories PRODUCTIVITY / UTILITIES')

    have_info = {x['attributes']['locale']: x for x in call('GET', f'/v1/appInfos/{info["id"]}/appInfoLocalizations')['data']}
    for ours, theirs in LOCALES.items():
        f = meta[ours]
        upsert('appInfoLocalizations', 'appInfo', 'appInfos', info['id'], have_info, theirs,
               {'name': f['name'], 'subtitle': f['subtitle'], 'privacyPolicyUrl': PRIVACY}, dry)
    # Creating an app info locale also creates the version's locale, so the version's are read after.
    have_ver = {x['attributes']['locale']: x for x in call('GET', f'/v1/appStoreVersions/{v["id"]}/appStoreVersionLocalizations')['data']}
    for ours, theirs in LOCALES.items():
        f = meta[ours]
        upsert('appStoreVersionLocalizations', 'appStoreVersion', 'appStoreVersions', v['id'], have_ver, theirs,
               {'description': f['description'], 'keywords': f['keywords'], 'promotionalText': f['promotional'],
                'supportUrl': SUPPORT, 'marketingUrl': MARKETING}, dry)

    builds = call('GET', f'/v1/builds?filter[app]={a["id"]}&filter[processingState]=VALID&sort=-uploadedDate&limit=1')['data']
    if not builds:
        print('no processed build yet: run apply again when `status` shows one VALID')
    elif not dry:
        call('PATCH', f'/v1/appStoreVersions/{v["id"]}/relationships/build', {'data': {'type': 'builds', 'id': builds[0]['id']}})
        print('build', builds[0]['attributes']['version'], 'attached')


def delivered(path, field='assetDeliveryState', timeout=300):
    """The asset's delivery state once Apple has processed it (COMPLETE or FAILED), with its errors; the last state seen at the
    timeout. A screenshot reports it in assetDeliveryState, a preview video in videoDeliveryState."""
    end = time.time() + timeout
    while True:
        at = call('GET', path)['data']['attributes']
        state = (at.get(field) or {}).get('state')
        if state in ('COMPLETE', 'FAILED') or time.time() > end:
            return state, (at.get(field) or {}).get('errors') or []
        time.sleep(2)


def shots(dry):
    a = app()
    v = editable_version(a['id'])
    print('version', v['attributes']['versionString'], v['attributes']['appStoreState'])
    files = {}
    for folder in ('ko', 'en'):
        d = os.path.join(SHOTS, folder)
        files[folder] = sorted(f for f in os.listdir(d) if f.endswith('.png')) if os.path.isdir(d) else []
        if not 1 <= len(files[folder]) <= 10:
            sys.exit(f'{d}: {len(files[folder])} PNGs (1 to 10 needed; run tools/app-store/screenshots/compose.sh)')
    have = {x['attributes']['locale']: x for x in call('GET', f'/v1/appStoreVersions/{v["id"]}/appStoreVersionLocalizations')['data']}
    for ours, theirs in LOCALES.items():
        folder = 'ko' if ours == 'ko' else 'en'
        loc = have.get(theirs) or sys.exit(f'no version localization {theirs}: run apply first')
        sets = call('GET', f'/v1/appStoreVersionLocalizations/{loc["id"]}/appScreenshotSets')['data']
        shot_set = next((x for x in sets if x['attributes']['screenshotDisplayType'] == 'APP_DESKTOP'), None)
        old = call('GET', f'/v1/appScreenshotSets/{shot_set["id"]}/appScreenshots')['data'] if shot_set else []
        print(f'{theirs}: APP_DESKTOP set {shot_set["id"] if shot_set else "(create)"}, delete {len(old)}, upload out/{folder} '
              f'{" ".join(files[folder])}')
        if dry:
            continue
        if not shot_set:
            shot_set = call('POST', '/v1/appScreenshotSets', {'data': {'type': 'appScreenshotSets',
                            'attributes': {'screenshotDisplayType': 'APP_DESKTOP'},
                            'relationships': {'appStoreVersionLocalization': {'data': {'type': 'appStoreVersionLocalizations', 'id': loc['id']}}}}})['data']
        for o in old:
            call('DELETE', f'/v1/appScreenshots/{o["id"]}')
        # the display order is the order of creation
        for name in files[folder]:
            data = open(os.path.join(SHOTS, folder, name), 'rb').read()
            shot = call('POST', '/v1/appScreenshots', {'data': {'type': 'appScreenshots',
                        'attributes': {'fileName': f'mwoyeo-{folder}-{name}', 'fileSize': len(data)},
                        'relationships': {'appScreenshotSet': {'data': {'type': 'appScreenshotSets', 'id': shot_set['id']}}}}})['data']
            for op in shot['attributes']['uploadOperations']:
                put_chunk(op['url'], op['method'], op.get('requestHeaders'), data[op['offset']:op['offset'] + op['length']])
            call('PATCH', f'/v1/appScreenshots/{shot["id"]}', {'data': {'type': 'appScreenshots', 'id': shot['id'],
                 'attributes': {'uploaded': True, 'sourceFileChecksum': hashlib.md5(data).hexdigest()}}})
            state, errors = delivered(f'/v1/appScreenshots/{shot["id"]}')
            print(f'  {name}: {state}', '; '.join(f'{e.get("code")}: {e.get("description")}' for e in errors))


def preview_problems(path):
    """What App Store Connect would fail a Mac preview for, read with ffprobe (skipped without it): 1920x1080, at most 30 fps,
    15 to 30 s, H.264 or ProRes, an audio track, at most 500 MB. Processing fails on these only after the upload."""
    problems = []
    if os.path.getsize(path) > 500 * 1024 * 1024:
        problems.append('over 500 MB')
    if not shutil.which('ffprobe'):
        return problems
    out = subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'stream=codec_type,codec_name,width,height,avg_frame_rate:format=duration',
                          '-of', 'json', path], capture_output=True, text=True)
    info = json.loads(out.stdout or '{}')
    video = [s for s in info.get('streams', []) if s.get('codec_type') == 'video']
    if not video:
        return problems + ['no video track']
    v = video[0]
    num, _, den = v.get('avg_frame_rate', '0/1').partition('/')
    fps = float(num) / float(den or 1) if float(den or 1) else 0
    seconds = float(info.get('format', {}).get('duration', 0))
    if (v.get('width'), v.get('height')) != (1920, 1080):
        problems.append(f'{v.get("width")}x{v.get("height")}, not 1920x1080')
    if fps > 30.01:
        problems.append(f'{fps:.2f} fps, over 30')
    if not 15 <= seconds <= 30:
        problems.append(f'{seconds:.2f} s, not 15 to 30')
    if v.get('codec_name') not in ('h264', 'prores'):
        problems.append(f'codec {v.get("codec_name")}')
    if not any(s.get('codec_type') == 'audio' for s in info.get('streams', [])):
        problems.append('no audio track')
    return problems


def previews(dry):
    a = app()
    v = editable_version(a['id'])
    print('version', v['attributes']['versionString'], v['attributes']['appStoreState'])
    files, posters = {}, {}
    for lang in ('ko', 'en'):
        files[lang] = os.path.join(PREVIEWS, f'{lang}.mp4')
        if not os.path.isfile(files[lang]):
            sys.exit(f'{files[lang]}: missing (run tools/app-store/previews/cut.sh)')
        problems = preview_problems(files[lang])
        if problems:
            sys.exit(f'{files[lang]}: {", ".join(problems)}')
        poster = os.path.join(PREVIEWS, f'{lang}.poster')
        posters[lang] = open(poster).read().strip() if os.path.isfile(poster) else None
    have = {x['attributes']['locale']: x for x in call('GET', f'/v1/appStoreVersions/{v["id"]}/appStoreVersionLocalizations')['data']}
    for ours, theirs in LOCALES.items():
        lang = 'ko' if ours == 'ko' else 'en'
        loc = have.get(theirs) or sys.exit(f'no version localization {theirs}: run apply first')
        sets = call('GET', f'/v1/appStoreVersionLocalizations/{loc["id"]}/appPreviewSets')['data']
        preview_set = next((x for x in sets if x['attributes']['previewType'] == 'DESKTOP'), None)
        old = call('GET', f'/v1/appPreviewSets/{preview_set["id"]}/appPreviews')['data'] if preview_set else []
        data_size = os.path.getsize(files[lang])
        # A rerun after a failure keeps what already went up: one preview of the same size that Apple took is not sent again.
        kept = [o for o in old if o['attributes'].get('fileSize') == data_size
                and ((o['attributes'].get('videoDeliveryState') or {}).get('state') in ('UPLOAD_COMPLETE', 'PROCESSING', 'COMPLETE'))]
        if len(old) == 1 and kept:
            print(f'{theirs}: DESKTOP set {preview_set["id"]}, already has out/{lang}.mp4 '
                  f'({(kept[0]["attributes"].get("videoDeliveryState") or {}).get("state")}), kept')
            continue
        print(f'{theirs}: DESKTOP set {preview_set["id"] if preview_set else "(create)"}, delete {len(old)}, upload out/{lang}.mp4 '
              f'({data_size} bytes), poster frame {posters[lang] or "(Apple default, 5 s)"}')
        if dry:
            continue
        if not preview_set:
            preview_set = call('POST', '/v1/appPreviewSets', {'data': {'type': 'appPreviewSets',
                               'attributes': {'previewType': 'DESKTOP'},
                               'relationships': {'appStoreVersionLocalization': {'data': {'type': 'appStoreVersionLocalizations', 'id': loc['id']}}}}})['data']
        for o in old:
            call('DELETE', f'/v1/appPreviews/{o["id"]}')
        data = open(files[lang], 'rb').read()
        attrs = {'fileName': f'mwoyeo-{lang}.mp4', 'fileSize': len(data), 'mimeType': 'video/mp4'}
        if posters[lang]:
            attrs['previewFrameTimeCode'] = posters[lang]
        preview = call('POST', '/v1/appPreviews', {'data': {'type': 'appPreviews', 'attributes': attrs,
                       'relationships': {'appPreviewSet': {'data': {'type': 'appPreviewSets', 'id': preview_set['id']}}}}})['data']
        for op in preview['attributes']['uploadOperations']:
            put_chunk(op['url'], op['method'], op.get('requestHeaders'), data[op['offset']:op['offset'] + op['length']])
        commit = {'uploaded': True, 'sourceFileChecksum': hashlib.md5(data).hexdigest()}
        if posters[lang]:
            commit['previewFrameTimeCode'] = posters[lang]
        call('PATCH', f'/v1/appPreviews/{preview["id"]}', {'data': {'type': 'appPreviews', 'id': preview['id'], 'attributes': commit}})
        # Apple says processing takes up to 24 h; a state still PROCESSING at the timeout is reported, not an error.
        state, errors = delivered(f'/v1/appPreviews/{preview["id"]}', 'videoDeliveryState', timeout=600)
        print(f'  {lang}.mp4: {state}', '; '.join(f'{e.get("code")}: {e.get("description")}' for e in errors))


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'status'
    if cmd == 'status':
        status()
    elif cmd == 'apply':
        apply('--dry' in sys.argv)
    elif cmd == 'shots':
        shots('--dry' in sys.argv)
    elif cmd == 'previews':
        previews('--dry' in sys.argv)
    else:
        sys.exit(__doc__)
