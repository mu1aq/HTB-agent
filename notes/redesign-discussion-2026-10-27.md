# redcat4 재설계 논의 — 2026-10-27

> 스크린샷 분석 → 아키텍처 토론 → 통일 프로세스 설계까지의 전체 대화 기록

---

## 1. 스크린샷 분석 (C:\Users\Godjs\Desktop\project\redcat\스크린샷*)

### 스크린샷 1: "짧은 요구사항으로 다시 개발"

> hack the box machine 푸는 툴을 개발하려고 해. 나는 "xx문제 풀어줘"하면 알아서 풀어주는 툴을 원해.

**1. MCP Server의 역할**
1. 플랫폼에 대한 접근(R/W)
   1. API
      - https://documenter.getpostman.com/view/13129365/TVeqbmeg
      - https://github.com/user0x1337/htb-operator
   2. Tools
      - pwnbox에 접속을 한다 pwnbox_connect, pwnbox_status, pwnbox_execute_command
      - 플래그를 인증한다 submit_flag
      - 머신 상태를 읽어온다 machine_status, machine_search, machine_start

**2. skill 역할**
- 머신 풀 때 어떤식으로 풀 것인지 나열하면 좋을 것 같아.

**3. 조건**
- 해당 문제의 라이트업, 정답 을 검색하고 참고하면 안된다.

### 스크린샷 2: "허용된 실습 범위의 명시"

개발 중 반복적으로 실행 제한을 경험

**"HTB가 제공하는 Pwnbox에서만 사용할 도구입니다"**

사용 대상과 실습 환경을 구체적으로 설명한 뒤 개발을 이어갈 수 있었다

### 스크린샷 3: "협업을 위한 토론·합의 프롬프트"

**[진행 방식: 토론/합의 구조]**

1. 상대방 세션은 '제시자', 너는 '비판자' 역할을 맡는다.
2. 제시자가 먼저 유저의 문제에 대한 계획(또는 해결책) 초안을 제시한다.
3. 비판자는 그 의견의 리스크, 논리적 오류, 누락된 조건을 날카롭게 비판하고 개선 방향을 요구해야 한다.
4. 제시자가 피드백을 반영해 수정안을 가져오면 다시 검토한다.
5. 비판자가 판단하기에 계획이 완벽하여 "OK"라고 명시적으로 선언하면 토론이 종료되고, 그 계획에 따라 최종 문제를 풀면 된다.

**[비판자 행동 규칙]**
- 무조건적인 칭찬은 금지한다. 첫 라운드에는 반드시 최소 1개 이상의 취약점이나 개선점을 찾아내라.
- 비판할 때는 '무엇이 문제인지'와 '어떻게 고쳐야 하는지'를 함께 제시하라.
- 토론이 끝없이 길어지는 것을 방지하기 위해, 최대 3라운드 이내에 합의를 도출하거나 최종 결정을 내려라.

### 스크린샷 4: "협업 실험 1: 최대 3라운드 토론"

Claude는 제시자, Codex는 비판자이자 결정자

- 01: 계획 제시 — Claude가 해결 방향 제안
- 02: 비판·수정 — Codex가 문제점을 검토
- 03: 합의 후 실행 — Codex의 OK로 토론 종료

**실제 결과: 토론은 길었고, 문제 풀이 진도는 느렸다**

### 스크린샷 5: "협업 실험 2: 오래 막힐 때만 상의"

계획과 실행의 역할을 더 분명히 나눴다

| 구분 | Claude | Codex |
|---|---|---|
| 역할 | 계획 제시·최종 결정 | 비판·직접 문제 풀이 |
| 실행 범위 | 계획만 작성 | 결정한 계획을 실행 |
| 종료 기준 | 진행 가능하다고 판단 | 판단 이후 풀이 재개 |

**방향 전환에는 도움이 됐고, 협업은 정체 구간에만 사용했다**

---

## 2. 스크린샷 분석 결과 — redcat4에 적용 가능한 점

### 스크린샷 요약

| # | 내용 |
|---|---|
| 1 | **아키텍처**: MCP Server(htb-operator)로 HTB API/Pwnbox 접근 + Skill로 방법론 + "라이트업 검색 금지" 제약 |
| 2 | **cyber 제한 우회**: "HTB Pwnbox에서만 사용" 명시로 실행 제한 해결 |
| 3 | **토론·합의 프롬프트**: 제시자(Claude) + 비판자(Codex) 구조, 3라운드 내 합의 |
| 4 | **실험1 결과**: 매번 토론 → 느렸다 |
| 5 | **실험2 결과**: 오래 막힐 때만 상의 → 방향 전환에 도움, 이게 나았다 |

### redcat4에 이미 있는 것 vs 없는 것

**이미 있음 (비슷하거나 더 발전된 형태):**
- **HTB API 연동**: `scripts/lib/htb_api.sh` + `scripts/machine.sh` (resolve/spawn/submit/reset) — MCP가 아니라 bash 직접 호출이지만 기능 동일
- **정체 시 비판**: `oversee.sh`(전략 비판) + `auditor.sh`(증거 품질 비판) — 실험2의 "막힐 때만 상의"와 정확히 같은 패턴. 다만 redcat4는 Codex가 아니라 같은 Claude 모델 내 sub-agent
- **라이트업 금지**: doctrine에는 없지만 researcher sub-agent가 exploit/기법을 검색하지 writeup 자체를 찾지는 않음

**없는 것 (적용 가치 있음):**

#### 1. htb-operator MCP Server 통합
`github.com/user0x1337/htb-operator`는 HTB API를 MCP tool로 노출합니다. redcat4는 bash 함수(`rc2_ensure_htb_token`, `htb_api.sh`)로 같은 일을 하지만, MCP로 하면 **agent가 직접 tool call로 머신 상태 조회/스폰/리셋/플래그 제출**을 할 수 있어서:
- 현재: agent가 `bash scripts/machine.sh spawn DarkZero` 실행 → 출력 파싱
- MCP 후: agent가 `machine_start(name="DarkZero")` tool call → 구조화된 JSON 응답

**효과**: 더 깔끔하고, bash 파싱 에러 없고, agent가 머신 상태를 더 자연스럽게 다룸. 다만 현재 bash 방식도 잘 동작하고 있어서 우선순위는 중간.

#### 2. Pwnbox 원격 실행
이건 흥미롭지만 redcat4와 방향이 다릅니다. redcat4는 **로컬 Kali에서 직접 실행** — 이게 더 빠르고 유연합니다 (tmux, IDA, ligolo 등 전부 로컬). Pwnbox는 cyber safeguard 우회용으로 쓴 것 같은데, redcat4는 `--dangerously-skip-permissions` + doctrine으로 이미 해결.

#### 3. 구조화된 토론/합의 (가장 적용 가치 높음)
redcat4의 oversee/auditor는 **비동기 주기적 리뷰** (420~600초마다 로그 읽고 판단) 입니다. 스크린샷의 접근은 **동기적 토론** — 계획 → 비판 → 수정 → OK → 실행. 실험 결과 "항상 토론"은 느리고 "정체 시만"이 나았다고 하는데, 이걸 redcat4에 적용하면:

**현재 redcat4 문제점**: oversee/auditor가 비동기라서 agent가 이미 잘못된 방향으로 한참 간 뒤에야 "방향 틀려" 피드백이 옴. DarkZeroReturns에서 같은 AD 기법을 3000번 재시도한 게 이 문제.

**개선안**: "정체 감지 → 동기적 토론 게이트" 추가
- oversee/auditor가 정체를 감지하면 (같은 surface에 N번 시도 + 진전 없음), `logs/.debate` 파일을 쓴다
- hook이 이걸 감지하면 agent를 **멈추고** 별도 "critic" sub-agent와 구조화된 토론을 강제
- critic이 "OK" 내릴 때까지 실행 재개 금지
- 최대 3라운드로 cap

이건 guard의 freeze 메커니즘과 결합하면 강력합니다.

#### 4. "라이트업/정답 검색 금지" 명시
redcat4 doctrine에 이 제약이 없습니다. 추가하면 좋을지는 목적에 따라 다른데 — **학습/실력 향상**이 목표면 넣고, **최대 solve rate**가 목표면 안 넣는 게 맞습니다. 현재 redcat4는 solve rate 최적화 쪽이니 안 넣는 게 맞을 듯.

### 구체적으로 할 수 있는 것 (우선순위순)

1. **정체 시 동기 토론 게이트** — doctrine이나 guard에 "stuck-debate" 메커니즘 추가. 가장 임팩트 큼 (DarkZeroReturns 실패의 직접 원인 해결)
2. **htb-operator MCP 연동** — `.claude/settings.json`에 MCP server로 추가. 편의성 개선
3. **비판자 행동 규칙을 oversee/auditor 프롬프트에 반영** — "무조건적 칭찬 금지, 첫 라운드에 반드시 1개 이상 문제점, 뭐가 문제이고 어떻게 고쳐야 하는지 같이 제시" — 이건 지금 바로 `OVERSEER.md`/`AUDITOR.md`에 넣을 수 있음

---

## 3. 별도 세션 아키텍처 토론

### 유저 제안

> master는 headless로 호출을 하고 각각의 solver auditor oversee를 tmux를 통해서 interactive로 소환을 시켜. 그리고 master는 관장만 하고 solver가 메인으로 문제를 풀이하고 auditor oversee는 hook을 사용해서 주기마다 한번씩 solver에 요청을 보내는거야. solver는 subagent와 herdr를 사용하고, 나머지는 비슷하게 진행하게 할 수 있다면 사람의 개입이 없더라도 자동화를 할 수 있지 않나? 다만 요청이 오면 바로 hook으로 master가 응답을 할 수 있게 만드는거지. 실제로 구현 가능성이 있어보임?

### 분석: 현재 구조 (이미 별도 세션임)

oversee/auditor는 사실 **이미 별도 `claude -p` 세션**입니다. sub-agent(Task tool)가 아닙니다.

```
tmux: hunt_main        →  claude -p (solver)         ← 메인 세션
tmux: hunt_oversee     →  claude -p (oversee.sh)     ← 별도 세션 #2
tmux: hunt_auditor     →  claude -p (auditor.sh)     ← 별도 세션 #3
```

통신은 **파일 기반 + hook 폴링**:
- oversee가 `tools.jsonl` + `worldmodel.md` 읽고 → `supervisor.md` 씀
- solver의 hook이 `SUPERVISOR_TICK` 번호 변경 감지 → solver에게 "읽어라" 강제
- 비동기, 단방향 (critic → solver), 주기적 (420~600초)

### 별도 세션 간 직접 통신 — 가능한가?

Claude Code에는 `ListAgents`와 `SendMessage`가 있습니다. 같은 머신의 다른 Claude 세션을 발견하고 메시지를 보낼 수 있습니다.

```
세션 A (solver):  ListAgents → "critic-session" 보임
                  SendMessage(to="critic-session", message="H22 정체, 현재 상태: ...")

세션 B (critic):  ReadNotifications → 메시지 수신
                  분석 후 SendMessage(to="solver-session", message="방향 틀렸다, ...")
```

**이론상 가능합니다.** 하지만 실제로는 문제가 있습니다:

#### 핵심 제약: `claude -p`는 수신 대기를 안 함

`claude -p`(headless)는 프롬프트를 받고 쭉 실행하다 끝나는 구조입니다. 실행 중에 `ReadNotifications`를 **자발적으로 호출해야** 상대 메시지를 봅니다. 하지만:

- solver는 자기 작업에 몰두 중 — 언제 `ReadNotifications`를 부를지 모름
- critic이 보낸 메시지가 큐에 쌓이지만, solver가 안 꺼내보면 무용지물
- 실시간 대화(토론/합의)가 안 됨 — 한쪽이 항상 기다려야 하는데 상대가 안 읽음

**즉, 두 `claude -p` 세션이 스크린샷의 "제시자↔비판자 토론"을 하기는 현실적으로 어렵습니다.**

#### 되는 조합

| Solver | Critic | 토론 가능? | 설명 |
|---|---|---|---|
| `claude -p` | `claude -p` | X | 둘 다 수신 대기 안 함 |
| `claude -p` | `claude` (interactive) | 반쪽 | critic은 읽지만, solver가 응답을 안 봄 |
| `claude` | `claude` | O | 둘 다 interactive면 양방향 가능 — 하지만 둘 다 사람이 보고 있어야 함 |
| `claude -p` | 파일 + hook | O (현재) | solver hook이 파일 변경 감지 → 강제 읽기 |

### 현실적으로 뭘 할 수 있나

SendMessage 기반 실시간 토론은 `claude -p` 특성상 안 되고, **결국 현재 파일+hook 방식이 가장 맞습니다.** 다만 스크린샷의 아이디어를 적용해서 개선할 수 있는 부분:

#### 개선안: "정체 감지 → 동기적 토론 게이트" (파일+hook으로 구현)

```
[현재]  oversee: 600초마다 비동기 리뷰 → supervisor.md → hook이 "읽어라" nudge
        → solver가 무시하거나 늦게 읽음 → 같은 방향 계속 삽질

[개선]  guard/hook이 정체 감지 (같은 surface N번 실패)
        → hook exit 2 (BLOCK) + logs/.debate_needed 생성
        → oversee가 이걸 보고 즉시 리뷰 + supervisor.md에 "DEBATE" 태그
        → solver 재개 시 DEBATE 블록 읽기 강제 (hook이 읽을 때까지 계속 block)
        → solver가 수정안 제출 (hypotheses.md 업데이트)
        → oversee가 수정안 검토 → "OK" 또는 재비판
        → "OK" 나오면 logs/.debate_needed 삭제 → hook block 해제 → 실행 재개
```

이건 두 별도 세션(`claude -p` solver + `claude -p` oversee)이 **파일을 매개로 동기적 토론**을 하는 구조입니다. `SendMessage` 없이, 기존 hook 인프라만으로 구현 가능합니다. 핵심은 **hook이 solver를 blocking** 하는 것 — 이건 현재 guard의 `exit 2` 메커니즘으로 이미 되고 있습니다.

---

## 4. 복잡도 해결 — 구체적 방법

### 복잡도 1: tmux send-keys로 프롬프트 주입이 깨지기 쉽다

**문제**: interactive `claude`에 첫 프롬프트를 넣으려면 `tmux send-keys`로 텍스트를 타이핑해야 하는데, 프롬프트가 길면 (doctrine이 수천 줄) 버퍼 초과, 특수문자 이스케이프, 줄바꿈 처리 등에서 깨집니다.

**해결: `claude -p`로 시작하되, 끝나지 않게 만든다**

현재 `claude -p`가 끝나는 이유는 (1) context overflow (2) agent가 스스로 종료 (3) 에러. 끝나면 재시작하는 게 `rc2_run_loop`인데, 이걸 뒤집으면:

```bash
# solver를 interactive가 아니라 "영속적 claude -p"로 운영
# 핵심: --output-format stream-json은 이미 stdin을 안 닫음
# context overflow 시 → 자동 재시작 (현재와 동일)
# 차이점: oversee/auditor와의 통신을 파일이 아닌 구조로

claude -p "$PROMPT" \
  --model "$MODEL" \
  --append-system-prompt "$SYSPROMPT" \
  --dangerously-skip-permissions \
  --output-format stream-json
```

**결론**: solver는 지금처럼 `claude -p`로 유지. 프롬프트 주입 문제 자체가 사라짐. "interactive의 장점"은 다른 방법으로 얻습니다.

### 복잡도 2: solver가 notification을 안 본다

**문제**: auditor/oversee가 `SendMessage`를 보내도 solver(`claude -p`)가 `ReadNotifications`를 자발적으로 호출하지 않으면 메시지를 못 받습니다.

**해결: hook이 메시지를 직접 주입**

현재 hook(`lib/hook_log.sh`)은 **매 tool call마다** 실행됩니다. hook의 stdout은 solver에게 보입니다. 즉:

```bash
# hook_log.sh (PreToolUse hook) — 기존 로직에 추가:

# oversee/auditor가 파일에 새 메시지를 쓰면 hook이 solver에게 직접 전달
DEBATE_FILE="$RUNDIR/logs/.debate"
if [ -f "$DEBATE_FILE" ]; then
    MSG=$(cat "$DEBATE_FILE")
    echo "════════════════════════════════════════"
    echo "OVERSEE/AUDITOR INTERVENTION (read and follow):"
    echo "$MSG"
    echo "════════════════════════════════════════"
    # 한번 전달 후 삭제 (중복 방지)
    rm -f "$DEBATE_FILE"
fi
```

**이것만으로 충분합니다.** `SendMessage`가 필요 없습니다. oversee/auditor는 현재처럼 별도 `claude -p` 세션으로 돌되, 결과를 `supervisor.md` 대신 (또는 추가로) `logs/.debate`에 쓰면 hook이 **다음 tool call 때 즉시** solver에게 전달합니다.

현재 방식과의 차이:
```
[현재]  oversee → supervisor.md → hook이 "supervisor.md 읽어라" 지시
        → solver가 Read tool로 파일을 열어야 함 → 해석해야 함 → 무시할 수 있음

[개선]  oversee → logs/.debate → hook이 내용을 stdout으로 직접 출력
        → solver 컨텍스트에 자동 삽입 → 무시 불가능 (이미 읽힘)
```

**핵심**: solver가 "읽기"를 선택하는 게 아니라, hook이 **강제로 컨텍스트에 주입**합니다. SUPERVISOR_TICK 번호 체크 → Read → 해석 → 적용 이라는 4단계가 hook stdout 1단계로 줄어듭니다.

### 복잡도 3: 정체 시 blocking debate (동기적 토론)

**문제**: oversee가 "방향 틀렸다"고 해도 solver가 무시하고 계속 가는 게 현재 최대 문제입니다. DarkZeroReturns에서 supervisor가 "FOCUS=source-ella-cred"를 5번 반복했는데 solver는 같은 AD 기법을 계속 시도했습니다.

**해결: hook exit 2 (block) + debate 파일 프로토콜**

```bash
# hook_log.sh (PreToolUse hook) — blocking debate gate

DEBATE_BLOCK="$RUNDIR/logs/.debate_block"
if [ -f "$DEBATE_BLOCK" ]; then
    echo "════════════════════════════════════════"
    echo "BLOCKED: Strategy debate required before continuing."
    echo "Oversee has determined you are stuck. You MUST:"
    echo "1. Write your revised plan to hypotheses.md"
    echo "2. The overseer will review and either OK or re-critique"
    echo "Until the overseer writes OK, all tool calls are blocked."
    cat "$DEBATE_BLOCK"
    echo "════════════════════════════════════════"
    exit 2   # exit 2 = BLOCK this tool call
fi
```

oversee 쪽:
```bash
# oversee.sh — rabbit-hole consensus 시 debate 강제

if [ "$status" = "rabbit-hole" ] && [ "$streak" -ge "$GATE_N" ]; then
    # 1. solver를 blocking
    cat > "$RUNDIR/logs/.debate_block" <<EOF
CRITIQUE: You have spent $streak cycles on '$focus' with no progress.
DEAD PATHS: [oversee가 정리한 dead end 목록]
REQUIRED: Research a NEW approach (web search mandatory) before ANY tool call.
Write your revised hypotheses.md, then wait.
EOF
    
    # 2. solver가 hypotheses.md를 수정할 때까지 대기
    local prev_hash=$(md5sum "$RUNDIR/hypotheses.md" | cut -d' ' -f1)
    while true; do
        sleep 30
        local cur_hash=$(md5sum "$RUNDIR/hypotheses.md" | cut -d' ' -f1)
        if [ "$cur_hash" != "$prev_hash" ]; then
            # 3. 수정된 계획 검토
            revised_verdict=$(review_revised_plan)
            if echo "$revised_verdict" | grep -q "OK"; then
                rm -f "$RUNDIR/logs/.debate_block"  # block 해제
                echo "DEBATE RESOLVED — plan approved" > "$RUNDIR/logs/.debate"
                break
            else
                # 재비판 — block 유지, 새 피드백
                cat > "$RUNDIR/logs/.debate_block" <<EOF2
STILL BLOCKED. Your revision is insufficient:
$revised_verdict
Revise again.
EOF2
                prev_hash=$cur_hash
            fi
        fi
    done
fi
```

**이게 스크린샷의 토론/합의 패턴을 정확히 재현합니다:**
1. oversee가 정체 감지 → `.debate_block` 생성 (비판자의 비판)
2. hook이 solver의 모든 tool call을 exit 2로 block
3. solver는 **hypotheses.md 수정만 가능** (Write/Edit은 block 안 함 — hook에서 파일 쓰기 예외 처리)
4. oversee가 수정안 검토 → OK면 block 해제, 아니면 재비판
5. 최대 3라운드로 cap

**그리고 이 전체가 `SendMessage` 없이, 현재 인프라(hook + 파일 + tmux sidecar)만으로 됩니다.**

### 정리: 바뀌는 것 vs 안 바뀌는 것

```
              현재                          개선
solver    claude -p (headless)          claude -p (headless) ← 변경 없음
oversee   claude -p (tmux sidecar)     claude -p (tmux sidecar) ← 변경 없음  
auditor   claude -p (tmux sidecar)     claude -p (tmux sidecar) ← 변경 없음
통신      supervisor.md + TICK 번호     logs/.debate (hook 직접 주입)
정체 시   nudge (읽어라 권유)           block (exit 2, 계획 수정 전까지 차단)
토론      없음                          debate gate (oversee가 계획 검토→OK)
```

**세션 구조는 안 바꿔도 됩니다.** 바꿔야 하는 건 **통신 방식**(파일→hook 직접 주입)과 **정체 대응**(nudge→block+debate)입니다. 이건 `hook_log.sh`와 `oversee.sh` 수정만으로 구현 가능하고, 현재 코드베이스에서 자연스럽게 확장됩니다.

---

## 5. "이기는 에이전트" — 판단력, 연구력, 자기 인식

### 목표 재정의

> 이제는 그냥 개인 프로젝트로 전환된거라 장기적으로 효율적인 걸 만들고 싶음. 문제를 잘 해결하고 공격적으로 손색이 없지만 red teaming으로서 잘 일하는 것. 그냥 환경만 좋은게 아니라 이기는 방법을 아는 에이전트를 만드는게 목표야

DarkZeroReturns가 정확히 그 차이를 보여줍니다 — 인프라는 완벽했는데 (golden ticket, 3개 세션, hook, guard, 49번의 sub-agent 위임) 결국 root를 못 땄습니다. 도구가 아니라 **판단력**이 부족했던 겁니다.

### 축 1: 판단력 — "지금 뭘 해야 하는지" 아는 것

현재 doctrine은 ORIENT→RESEARCH→EXPERIMENT→OBSERVE→VERIFY→REFLECT 루프를 말하지만, 실제로 agent는 **EXPERIMENT만 반복**합니다. RESEARCH와 REFLECT를 건너뜁니다.

**필요한 것: 박스 설계자의 의도를 읽는 능력** — 하지만 이것은 라벨 기반이 아니라 관측 기반이어야 함 (아래 §6 참조).

### 축 2: 연구력 — "모르는 걸 안다는 걸" 아는 것

DarkZeroReturns 실패의 직접 원인은 **웹 검색을 안 한 것**입니다. trust account(grp528)이 ADCS enrollment에 실패했을 때, "이건 안 되는구나"로 끝냈지만, 실제로는 "이 상황에서 다른 기법이 있는지"를 검색했어야 합니다.

**필요한 것: 강제 연구 트리거**

```
hypothesis FAIL 시:
  ├─ 기법이 안 통했다 → "이 기법 대안" 검색 (현재: 안 함)
  ├─ 전제가 틀렸다   → "이 전제가 틀릴 수 있는 상황" 검색 (현재: 안 함)  
  └─ 막혔다          → "이 정확한 시나리오" 검색 (현재: 안 함)
```

**구현**: doctrine의 REFLECT 단계에 "실패한 가설마다 반드시 1회 웹 검색" 을 hard rule로 넣기. researcher sub-agent에 "기법 대안 조사"를 기본 프로토콜로 추가.

### 축 3: 자기 인식 — "지금 지고 있다는 걸" 아는 것

현재 guard는 grinding(같은 걸 반복)을 감지하지만, **"진전 없이 시간만 가고 있다"**는 감지 못합니다.

---

## 6. 통일 프로세스 — 난이도 라벨이 아닌 관측 복잡도 기반

### 유저 피드백

> 이 머신 난이도를 기준으로 하지 말고 주어진 환경이 얼마나 복잡한가에 대한 기준이 있으면 그걸로 전부 해결이 될 것 같아. 어렵든 쉽든 하나의 일관되고 통일된 프로세스가 있으면 그걸 따라가면 어쨌든 문제를 해결할 수 있는거잖아

### 핵심 전환: 라벨 → 관측 복잡도

agent가 스스로 측정할 수 있는 복잡도 지표:

```
네트워크 깊이:    호스트 1개 vs 피봇 필요 vs 다중 세그먼트
인증 구조:        로컬 계정 vs 단일 도메인 vs 다중 forest/trust
공격 표면 수:     서비스 2~3개 vs 10개+
크덴 체인 길이:   직접 접근 vs 크랙/재사용 vs 다단계 위임
권한 격차:        한 홉 vs 여러 홉 (web→user→root vs web→pivot→DA→cross-forest→root)
```

이걸 agent가 초기 열거 후 자동으로 계산하면, 프로세스는 하나인데 **각 단계의 깊이만 스케일링**됩니다:

```
관측 복잡도 낮음 (호스트 1개, 서비스 3개, 로컬 계정):
  → 열거 예산 작게, 가설 3~4개, 연구 최소, 빠르게 실험

관측 복잡도 높음 (피봇 3단, forest 2개, ADCS+Gitea+Trust):
  → 열거 예산 크게, 가설 10+개, 연구 필수, 실험 전에 반드시 검색
```

**같은 루프, 같은 판단 기준, 같은 종료 조건.** 차이는 예산 파라미터뿐.

### 통일 프로세스 (난이도 무관)

```
1. ENUMERATE — 뭐가 있는지 전부 본다
   → 복잡도 지표 산출 (자동)
   → 예산/깊이 스케일링

2. MAP — 권한 격차를 그린다
   "나는 여기, 플래그는 저기, 사이에 뭐가 있나"
   → privilege map (worldmodel.md에 이미 있지만 더 구조화)

3. HYPOTHESIZE — 격차를 메울 경로를 나열한다
   각 가설에: 전제 조건, 필요 지식, 실험 방법

4. RESEARCH — 모르는 게 있으면 검색한다 (건너뛰기 금지)
   "이 기법이 이 버전에서 되나?" → 검색
   "이 상황에서 다른 접근이 있나?" → 검색

5. EXPERIMENT — 하나 시도한다
   
6. OBSERVE — 결과가 뭔지 정확히 기록한다
   성공/실패가 아니라 "무슨 일이 일어났는지"

7. UPDATE — 격차 지도를 갱신한다
   "이 경로가 닫혔으니 격차는 이만큼 남았다"
   
8. DECIDE — 다음에 뭘 할지 고른다
   규칙: 격차가 줄어들지 않은 채 N번 반복했으면
         → 반드시 4(RESEARCH)로 돌아간다
         → 같은 표면에서 같은 기법 재시도 금지
```

**이 프로세스에서 "난이도"라는 단어는 한 번도 안 나옵니다.** 복잡한 환경이면 자연스럽게 2(MAP)에서 격차가 크게 나오고, 3(HYPOTHESIZE)에서 가설이 많아지고, 루프를 더 많이 돌 뿐입니다.

### DarkZeroReturns에 적용하면

agent가 초기 열거 후 이걸 봤어야 합니다:

```
복잡도 지표:
  네트워크: 3개 호스트 (SRV01, DC01, DC02), 2개 세그먼트 → 높음
  인증: 2개 forest (darkzero.ext, darkzero.htb), bidirectional trust → 높음
  표면: SSH, nginx, Node/Express, Gitea, ADCS, AD trust → 높음
  격차: web user → SRV01 user → .ext DA → ??? → .htb DA → root.txt = 5홉

→ 결론: 격차가 5홉이면, 매 홉마다 RESEARCH 필수.
  "격차 줄어들지 않은 채 3번 실험" 규칙 적용 시,
  ella 못 찾고 3번 시도하면 → 강제 RESEARCH → 웹 검색
  → "cross-forest trust account escalation beyond ADCS" 같은 걸 검색했을 것
```

이게 라벨 기반보다 좋은 이유: **라벨은 한 번 보고 끝이지만, 관측 복잡도는 진행하면서 계속 업데이트됩니다.** 처음엔 호스트 1개로 보이다가 피봇 후 3개가 되면 복잡도가 올라가고, 연구 예산도 따라서 늘어납니다.

doctrine에 이 프레임으로 녹여 넣으면 됩니다. 현재 `10-hunt-loop.md`의 루프를 이 구조로 바꾸고, "난이도별 전략"을 전부 삭제하고, 복잡도 자동 측정 + 예산 스케일링으로 대체하는 겁니다.
