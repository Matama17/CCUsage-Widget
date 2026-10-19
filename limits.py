#!/usr/bin/env python3
"""플랜 한도(실제 남은 사용량) 수집기.

`claude -p "/usage"` 출력을 파싱한다. 한도 값은 서버가 주는 것이라
~/.claude/projects 의 JSONL 에는 없다. 호출에 약 4초 걸리므로 TTL 캐시를 둔다.
"""
import json, os, re, shutil, subprocess, time
from datetime import datetime

CACHE_DIR = os.path.expanduser("~/Library/Caches/CCUsage")
CACHE = os.path.join(CACHE_DIR, "limits-cache.json")
TTL = 300          # 5분
TIMEOUT = 25

# "Current session: 29% used · resets Sep 7 at 3:09am (Asia/Seoul)"
LINE = re.compile(
    r"^Current\s+(?P<scope>[^:]+):\s+(?P<pct><?\s*\d+)%\s+used\s*[·\-]\s*resets\s+(?P<reset>[^(]+?)\s*(?:\((?P<tz>[^)]+)\))?\s*$"
)


def parse_reset(text, now=None):
    """'Sep 7 at 3:09am' / 'Sep 13 at 6pm' -> epoch seconds (실패 시 None)."""
    now = now or datetime.now()
    text = text.strip().replace(" at ", " ")
    for fmt in ("%b %d %I:%M%p", "%b %d %I%p", "%b %d %H:%M"):
        try:
            # 연도를 명시해야 윤일 파싱과 경고 문제를 피한다.
            dt = datetime.strptime(f"{text} {now.year}", fmt + " %Y")
        except ValueError:
            continue
        # 연말 경계: 파싱 결과가 한참 과거면 내년으로 본다.
        if (now - dt).days > 180:
            dt = dt.replace(year=now.year + 1)
        return dt.timestamp()
    return None


def label_for(scope):
    s = scope.strip().lower()
    if s == "session":
        return "session", "세션"
    m = re.match(r"week\s*\((.+)\)", s)
    if m:
        inner = m.group(1)
        if "all" in inner:
            return "week", "주간 전체"
        return "week_model", "주간 " + m.group(1).strip().title()
    return s.replace(" ", "_"), scope.strip()


def parse(output):
    out = []
    for line in output.splitlines():
        m = LINE.match(line.strip())
        if not m:
            continue
        scope, label = label_for(m.group("scope"))
        pct = int(re.sub(r"\D", "", m.group("pct")) or 0)
        out.append({
            "scope": scope,
            "label": label,
            "used": pct,
            "reset": parse_reset(m.group("reset")),
            "reset_text": m.group("reset").strip(),
        })
    return out


def load_cache():
    try:
        with open(CACHE) as f:
            return json.load(f)
    except Exception:
        return None


def claude_bin():
    """`claude` 실행 파일 경로.

    launchd 로 띄운 앱의 PATH 는 /usr/bin:/bin:/usr/sbin:/sbin 뿐이라
    로그인 셸의 PATH 에만 있는 claude 를 찾지 못한다. 흔한 설치 위치를
    직접 뒤진 뒤, 없으면 PATH 검색에 맡긴다.
    """
    for c in (os.path.expanduser("~/.local/bin/claude"),
              "/opt/homebrew/bin/claude",
              "/usr/local/bin/claude"):
        if os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    return shutil.which("claude") or "claude"


AUTH_HINT = re.compile(r"log ?in|sign ?in|authenticat|unauthorized|api key|credential|/login",
                       re.IGNORECASE)


def run_once():
    """한 번 호출해서 (한도 목록, 실패 사유) 를 돌려준다. 성공하면 사유는 None."""
    try:
        p = subprocess.run([claude_bin(), "-p", "/usage"],
                           capture_output=True, text=True, timeout=TIMEOUT,
                           cwd=os.path.expanduser("~"),
                           # stdin 을 닫지 않으면 CLI 가 파이프 입력을 3초 기다린다.
                           # 그만큼 매 호출이 느려지고, 드물게 그대로 멈춘다.
                           stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return [], "응답 지연"
    except Exception:
        return [], "실행 실패"

    limits = parse(p.stdout)
    if limits:
        return limits, None
    # 돌긴 돌았는데 한도 줄이 없다. 로그인이 풀린 경우가 대부분이라 구분해 준다.
    blob = (p.stdout or "") + (p.stderr or "")
    if AUTH_HINT.search(blob):
        return [], "로그인 필요"
    return [], "해석 실패" if p.returncode == 0 else "실행 실패"


def fetch(force=False):
    cached = load_cache()
    if not force and cached and time.time() - cached.get("fetched", 0) < TTL:
        return cached

    limits, reason = run_once()
    if not limits and reason != "로그인 필요":
        # 한 번 실패했다고 바로 '갱신 실패' 를 띄우면 일시적인 끊김에도 위젯이 깜빡인다.
        # 로그인 문제는 다시 시도해도 결과가 같으므로 재시도하지 않는다.
        time.sleep(2)
        limits, reason = run_once()

    if not limits:
        # 실패하면 마지막으로 성공한 값을 사유와 함께 유지한다.
        if cached and cached.get("limits"):
            cached["stale"] = True
            cached["reason"] = reason
            save_cache(cached)
            return cached
        return {"fetched": time.time(), "limits": [], "stale": True, "reason": reason}

    result = {"fetched": time.time(), "limits": limits, "stale": False, "reason": None}
    save_cache(result)
    return result


def save_cache(result):
    try:
        os.makedirs(os.path.dirname(CACHE), exist_ok=True)
        tmp = CACHE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(result, f)
        os.replace(tmp, CACHE)
    except OSError:
        pass


if __name__ == "__main__":
    import sys
    json.dump(fetch(force="--force" in sys.argv), sys.stdout, ensure_ascii=False, indent=1)
    print()
