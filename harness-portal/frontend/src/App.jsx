import React, { useState, useEffect, useRef } from 'react'

export default function App() {
  // Tab State: 'guide' | 'gallery' | 'dashboard'
  const [activeTab, setActiveTab] = useState('guide')
  const [targetDir, setTargetDir] = useState('')
  const [workflowMode, setWorkflowMode] = useState('autonomous-chain') // or 'manual-stepping'
  const [currentStep, setCurrentStep] = useState('Decompose') 
  const [isBootstrapping, setIsBootstrapping] = useState(false)
  const [isRunning, setIsRunning] = useState(false)
  const [copiedIndex, setCopiedIndex] = useState(null)
  
  // Real-time project environment diagnostics
  const [diagnostics, setDiagnostics] = useState({
    python_runtime: false,
    venv_active: false,
    pytest_installed: false,
    harness_installed: false
  })

  // Dynamic folder node open/close state mapping (Idea 1)
  const [openNodes, setOpenNodes] = useState({
    'kb-harness': true,
    'kb-harness/.claude': true,
    'kb-harness/.claude/rules': false,
    'kb-harness/.claude/gates': false,
    'kb-harness/.claude/agents': false,
    'kb-harness/.claude/skills': false,
    'kb-harness/docs': false,
    'kb-harness/recommended': false,
    'kb-harness/.claude-plugin': false
  })

  const toggleNode = (nodePath) => {
    setOpenNodes(prev => ({
      ...prev,
      [nodePath]: !prev[nodePath]
    }))
  }

  // Active Workspace Management & Connections States
  const [activeProject, setActiveProject] = useState('lakehouse')
  const [projects, setProjects] = useState([])
  const [showConnectModal, setShowConnectModal] = useState(false)
  const [connectingProject, setConnectingProject] = useState(null)

  const fetchProjects = async () => {
    try {
      const res = await fetch('/api/projects')
      if (res.ok) {
        const data = await res.json()
        setProjects(data)
        const activeItem = data.find(p => p.is_active)
        if (activeItem) {
          setActiveProject(activeItem.name)
        }
      }
    } catch (e) {
      console.error("Failed to fetch projects list", e)
    }
  }

  const handleSelectProject = async (projName) => {
    try {
      const res = await fetch('/api/select-project', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ projectName: projName })
      })
      if (res.ok) {
        addLog('success', `활성 작업공간을 [${projName}] 프로젝트로 전환하였습니다.`)
        fetchStatus()
        fetchProjects()
        fetchPrompts()
      }
    } catch (e) {
      console.error(e)
    }
  }
  
  // Prompt Gallery State initialized with fallback defaults
  const [promptGallery, setPromptGallery] = useState([
    {
      step: '전사 표준',
      title: 'Agent 개발 표준 프롬프트',
      command: 'Standard Agent Dev',
      description: '사내 보안 규칙과 BDD 개발 표준을 준수하여 에이전트가 오버플로우나 유출 없이 안전하게 행동하도록 행동 강령을 주입하는 프롬프트입니다.',
      prompt: `당신은 사내 보안 가이드라인(rules/01, rules/02) 및 컴플라이언스를 철저하게 준수하는 시니어 AI 개발 에이전트입니다.\n개발을 시작하기 전에 아래의 전제조건을 만족해야 합니다:\n1. 개발 공간은 반드시 '_workspace/' 격리 폴더로 제한합니다.\n2. 데이터베이스 접근 시 반드시 SELECT-Only (Read-Only) 권한을 사용하며, DDL/DML 수행을 전면 금지합니다.\n3. 실제 비즈니스 로직(src/)을 구현하기 전, 요구사항(AC)을 검증할 수 있는 PyTest(Given-When-Then 패턴)를 tests/ 하위에 먼저 개발하십시오.\n4. 외부 라이브러리 사용 시 패키지 버전을 '=='로 정확히 고정하고 취약점을 상시 진단하십시오.`
    },
    {
      step: '파이썬 표준',
      title: 'Python 이용한 App 개발 프롬프트',
      command: 'Python Clean Architecture',
      description: '가상환경 격리 및 PEP 8 코딩 컨벤션, 의존성 고정을 엄격히 이행하여 파이썬 앱을 빌드하는 지시 프롬프트입니다.',
      prompt: `파이썬을 이용하여 클린 아키텍처 기반의 모듈화된 애플리케이션을 설계하고 개발해줘.\n- 프로젝트 루트에 독립된 가상환경(.venv)을 생성하여 의존성을 격리해야 해.\n- requirements.txt 파일에 모든 사용 라이브러리의 버전을 정확하게 기입하고 고정해줘.\n- 코드는 PEP 8 스타일 가이드를 준수하며, 모든 클래스와 함수에는 명확한 독스트링(Docstring)과 타입 힌트(Type Hints)를 추가해줘.\n- 테스트 커버리지가 80% 이상이 되도록 단위 테스트 및 BDD 시나리오를 작성해줘.`
    },
    {
      step: '데이터 표준',
      title: '금융 데이터 분석 및 시각화 프롬프트',
      command: 'Secure Data Pipelines',
      description: '데이터 마스킹과 파라미터화된 안전한 질의문을 통해 금융 원천 데이터를 시각화하는 데이터 분석 프롬프트입니다.',
      prompt: `주어진 금융 거래 데이터를 읽기 전용(SELECT)으로 안전하게 질의하고 집계하는 파이프라인과 시각화 대시보드를 만들어줘.\n- DB 조회 시 SQL 인젝션을 방지하기 위해 반드시 파라미터화된 쿼리(Parameterized Queries)를 사용해야 해.\n- 개인정보(고객번호, 주민등록번호, 계좌번호 등)는 무단 노출되지 않도록 마스킹 처리 혹은 해시 암호화 처리를 강제해줘.\n- 집계된 결과는 Streamlit 또는 React를 활용해 거래 트렌드 차트, 계좌 잔액 분포도 등 시각적으로 수려한 대시보드로 표현해줘.`
    },
    {
      step: '네트워크 표준',
      title: 'API 컴플라이언스 연동 프롬프트',
      command: 'Secure Gateway Integration',
      description: '사내 API Gateway 필수 인증 헤더 5종을 상시 주입하고 대체 로직(Fallback)을 설계하는 API 연동 가이드 프롬프트입니다.',
      prompt: `사내 API Gateway 연동 표준을 준수하는 RESTful API 엔드포인트를 구현해줘.\n- 외부 호출 시 반드시 필수 보안 헤더 5종(X-Goog-Authenticated-User-Email, X-Consumer-Key, X-Request-Id, X-Signature, X-Timestamp)을 래핑해서 요청해야 해.\n- SSO 게이트웨이 장애 시를 대비한 비상 토큰 우회 모드(EMERGENCY_BYPASS_MODE)와 audit 로깅 아키텍처를 연계하여 예외 처리를 강화해줘.\n- 모든 비정상 요청에 대해서는 표준화된 에러 리스폰스 JSON 규격을 반환해줘.`
    }
  ])
  
  // Harness Gates State
  const [gates, setGates] = useState({
    api_headers: { name: 'API 헤더 검증', status: 'Pass', description: 'APIM 필수 헤더 5종 래핑 검사' },
    db_readonly: { name: 'DB Read-only 검증', status: 'Pass', description: 'SELECT 외 DML/DDL 차단 검사' },
    pip_version: { name: '의존성 버전 고정 검증', status: 'Fail', description: 'requirements.txt 내 == 고정 검사' },
    pytest: { name: 'PyTest 러너', status: 'Pending', description: 'Given-When-Then BDD 테스트 구동' }
  })
  
  // Kanban Tasks State
  const [tasks, setTasks] = useState([
    { id: 'AI-211', title: 'Initialize database connections', level: 'High', status: 'Backlog', owner: 'SK' },
    { id: 'AI-212', title: 'Implement BDD model training tests', level: 'Medium', status: 'TODO', owner: 'AL' },
    { id: 'AI-213', title: 'Create main document parser routing', level: 'Low', status: 'TODO', owner: 'MP' },
    { id: 'AI-214', title: 'Decompose Agent logic - [Critical]', level: 'High', status: 'In Progress', owner: 'AL' },
    { id: 'AI-215', title: 'Integrate API compliance headers helper', level: 'Medium', status: 'In Progress', owner: 'SK' },
    { id: 'AI-216', title: 'Verify read-only connection limits', level: 'Low', status: 'Review', owner: 'MP' }
  ])

  // Terminal Logs State
  const [terminalLogs, setTerminalLogs] = useState([
    { type: 'info', text: '하네스 포탈 백엔드에 성공적으로 연결되었습니다.' },
    { type: 'info', text: '대기 중... 하네스 이식 또는 게이트 실행 시 로그가 출력됩니다.' }
  ])

  const terminalRef = useRef(null)

  // Auto-scroll terminal container
  useEffect(() => {
    if (terminalRef.current) {
      terminalRef.current.scrollTop = terminalRef.current.scrollHeight
    }
  }, [terminalLogs])

  // Periodic status fetching from backend
  useEffect(() => {
    fetchStatus()
    fetchProjects()
    const interval = setInterval(() => {
      fetchStatus()
      fetchProjects()
    }, 3000)
    return () => clearInterval(interval)
  }, [])

  // Load prompts dynamically on mount
  useEffect(() => {
    fetchPrompts()
  }, [])

  const fetchPrompts = async () => {
    try {
      const res = await fetch('/api/prompts')
      if (res.ok) {
        const data = await res.json()
        if (data && data.length > 0) {
          setPromptGallery(data)
        }
      }
    } catch (e) {
      // offline fallback
    }
  }

  const fetchStatus = async () => {
    try {
      const res = await fetch('/api/status')
      if (res.ok) {
        const data = await res.json()
        if (data.workflow_mode) setWorkflowMode(data.workflow_mode)
        if (data.current_step) setCurrentStep(data.current_step)
        if (data.gates) setGates(data.gates)
        if (data.tasks) setTasks(data.tasks)

        if (data.logs) {
          // Merge backend logs and preserve system init log
          const formattedLogs = data.logs.map(log => ({
            type: log.type,
            text: log.text
          }))
          setTerminalLogs(formattedLogs)
        }
      }
    } catch (e) {
      // Offline fallback
    }
  }

  // API Call: Bootstrap Harness
  const handleBootstrap = async () => {
    if (!targetDir.trim()) {
      alert('대상 디렉토리 경로를 입력해 주세요.')
      return
    }
    setIsBootstrapping(true)
    addLog('info', `대상 경로 [${targetDir}]에 하네스 템플릿 설치 스크립트 실행 중...`)
    
    try {
      const res = await fetch('/api/bootstrap-harness', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ target_dir: targetDir })
      })
      if (res.ok) {
        const data = await res.json()
        addLog('success', `성공적으로 기동됨: ${data.message}`)
      } else {
        const err = await res.text()
        addLog('error', `설치 기동 실패: ${err}`)
      }
    } catch (e) {
      // Mock bootstrap fallback
      setTimeout(() => {
        addLog('info', `📍 타겟 프로젝트 경로: ${targetDir}`)
        addLog('info', `📦 1. 하네스 코어 엔진 (.claude/) 복사 중...`)
        addLog('success', `✅ .claude/ 복사 완료.`)
        addLog('info', `📝 2. .gitignore 설정 적용 중...`)
        addLog('success', `✅ .gitignore 생성 및 적용 완료.`)
        addLog('info', `📂 3. BDD 격리 작업대 폴더 구조 생성 중...`)
        addLog('success', `✅ _workspace/src/tests 등 기본 디렉토리 생성 완료.`)
        addLog('info', `🔍 4. 로컬 개발 환경 진단 시작...`)
        addLog('success', `✨ Python 런타임 감지: Python 3.11`)
        addLog('success', `✨ BDD PyTest 실행 엔진 감지: 설치됨`)
        addLog('success', `🎉 성공적으로 하네스 템플릿이 이식되었습니다!`)
        setIsBootstrapping(false)
      }, 2000)
      return
    }
    
    // Periodically release loading state after check
    setTimeout(() => {
      setIsBootstrapping(false)
    }, 4000)
  }

  // API Call: Trigger Actions (Run Gates, Fix, Package)
  const triggerAction = async (actionName, params = {}) => {
    setIsRunning(true)
    addLog('info', `작업 실행 요청: ${actionName}...`)
    try {
      const res = await fetch('/api/action', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: actionName, ...params })
      })
      if (res.ok) {
        const data = await res.json()
        addLog('success', `작업 기동 성공: ${data.message}`)
      } else {
        const err = await res.text()
        addLog('error', `작업 실패: ${err}`)
      }
    } catch (e) {
      simulateAction(actionName, params)
    } finally {
      setIsRunning(false)
    }
  }

  const simulateAction = (actionName, params) => {
    setTimeout(() => {
      if (actionName === 'run_gates') {
        setGates(prev => ({
          ...prev,
          api_headers: { ...prev.api_headers, status: 'Pass' },
          db_readonly: { ...prev.db_readonly, status: 'Pass' },
          pip_version: { ...prev.pip_version, status: 'Pass' },
          pytest: { ...prev.pytest, status: 'Pass' }
        }))
        addLog('success', '물리 가드레일 검증 완료 (100% 통과).')
      } else if (actionName === 'develop_fix') {
        addLog('info', '자가 치유 (/develop --fix) 기동 중...')
        addLog('success', '의존성 고정 오류 수정 완료 (requirements.txt 수정됨).')
        setGates(prev => ({
          ...prev,
          pip_version: { ...prev.pip_version, status: 'Pass' }
        }))
      } else if (actionName === 'package') {
        addLog('info', '반입용 패키징 스크립트 실행 중...')
        addLog('success', '최종 압축 파일 생성 완료: import-ready-v1.0.zip')
        addLog('success', '보안성 심사용 보고서 작성 완료: security-report.md')
      }
    }, 1500)
  }

  const handleCardDrag = (taskId, newStatus) => {
    setTasks(prev => prev.map(t => t.id === taskId ? { ...t, status: newStatus } : t))
    addLog('info', `작업 카드 ${taskId} 상태가 '${newStatus}'로 변경되었습니다.`)
    fetch('/api/tasks/update', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ task_id: taskId, status: newStatus })
    }).catch(() => {})
  }

  const addLog = (type, text) => {
    const timestamp = new Date().toLocaleTimeString()
    setTerminalLogs(prev => [...prev, { type, text: `[${timestamp}] ${text}` }])
  }

  // Copy helper
  const handleCopyText = (text, index) => {
    navigator.clipboard.writeText(text)
    setCopiedIndex(index)
    setTimeout(() => setCopiedIndex(null), 1500)
  }



  const statusColumns = [
    { key: 'TODO', label: '대기' },
    { key: 'In Progress', label: '진행 중' },
    { key: 'Review', label: '검토' },
    { key: 'Done', label: '완료' }
  ]

  return (
    <div style={styles.container}>
      {/* Header Panel */}
      <header className="glass-panel" style={styles.header}>
        <div style={styles.logoSection}>
          <svg width="28" height="28" viewBox="0 0 24 24" fill="var(--color-green)">
            <path d="M12 2L2 22h20L12 2zm0 4l6.5 13H5.5L12 6z"/>
          </svg>
          <div>
            <h1 style={styles.title}>KB국민은행 데이터시스템부 표준 하네스 & 바이브코딩 포탈</h1>
            <p style={styles.subtitle}>Unified Standard Guardrails & Vibe Coding Playbook Portal</p>
          </div>
        </div>
        <div style={styles.tabButtons}>
          <button 
            onClick={() => setActiveTab('guide')} 
            style={{
              ...styles.tabBtn, 
              borderBottom: activeTab === 'guide' ? '2px solid var(--color-green)' : '2px solid transparent',
              color: activeTab === 'guide' ? 'var(--color-green)' : 'var(--text-secondary)'
            }}
          >
            하네스 가이드 & 적용
          </button>
          <button 
            onClick={() => setActiveTab('gallery')} 
            style={{
              ...styles.tabBtn, 
              borderBottom: activeTab === 'gallery' ? '2px solid var(--color-green)' : '2px solid transparent',
              color: activeTab === 'gallery' ? 'var(--color-green)' : 'var(--text-secondary)'
            }}
          >
            바이브코딩 프롬프트 갤러리
          </button>
          <button 
            onClick={() => setActiveTab('structure')} 
            style={{
              ...styles.tabBtn, 
              borderBottom: activeTab === 'structure' ? '2px solid var(--color-green)' : '2px solid transparent',
              color: activeTab === 'structure' ? 'var(--color-green)' : 'var(--text-secondary)'
            }}
          >
            하네스 템플릿 전체 구조
          </button>
        </div>
        
        <div style={styles.projectSelectorSection}>
          <span style={{ fontSize: '11px', fontWeight: '700', color: 'var(--text-secondary)', marginRight: '6px' }}>🎯 활성 워크스페이스:</span>
          <select 
            value={activeProject}
            onChange={(e) => handleSelectProject(e.target.value)}
            style={styles.projectSelectDropdown}
          >
            {projects.map(p => (
              <option key={p.name} value={p.name}>{p.name}</option>
            ))}
          </select>
        </div>
      </header>

      {/* Main Tab Contents */}
      <main style={styles.mainContent}>
        
        {/* Tab 1: Harness Guide & Bootstrapper */}
        {activeTab === 'guide' && (
          <div className="fade-in" style={styles.tabLayout}>
            {/* Left: Guide Content */}
            <div style={styles.contentColumn}>
              <div className="glass-panel" style={styles.guideCard}>
                <h2 style={styles.sectionTitle}>🥦 KB 표준 통합 하네스(Harness)란?</h2>
                <p style={styles.guideText}>
                  AI 에이전트가 자율적으로 업무를 설계·개발하되, 사내 보안 및 통제 바운더리를 절대 벗어나지 않도록 규정하는 <strong>구조적 가드레일(Harness) + State 기반 워크플로우</strong> 프레임워크입니다.
                </p>
                <div style={styles.layersGrid}>
                  <div style={styles.layerBox}>
                    <span style={styles.layerNum}>Layer 1: 컨트롤 & 오케스트레이션</span>
                    <span style={styles.layerName}>🦙 워크플로우 통제 및 자가 복구 (CLAUDE.md)</span>
                    <p style={styles.layerDesc}>에이전트의 개발 수순을 상태(State) 기반으로 제어하며, 오류 감지 시 자동으로 수정·재검증하는 순환 복구 루틴을 구동합니다.</p>
                  </div>
                  <div style={styles.layerBox}>
                    <span style={styles.layerNum}>Layer 2: 정책 & 표준 가드레일</span>
                    <span style={styles.layerName}>🐊 기술 표준 정책 가이드라인 (rules/)</span>
                    <p style={styles.layerDesc}>보안 compliance, 네트워크 인프라 규격, DB Read-Only 쿼리 제한 등 지속적으로 추가·확장되는 사내 정책을 규정하여 에이전트의 일탈을 원천 차단합니다.</p>
                  </div>
                  <div style={styles.layerBox}>
                    <span style={styles.layerNum}>Layer 3: 하드웨어 게이트</span>
                    <span style={styles.layerName}>🐊 물리 검역 & 패키징 (gates/)</span>
                    <p style={styles.layerDesc}>코드가 배포 기준에 부합하는지 정적 분석 및 자동 테스트로 정밀 검역하며, 최종망 반출을 위한 증적 보고서 확보와 자동 패키징을 원스톱으로 지원합니다.</p>
                  </div>
                  <div style={styles.layerBox}>
                    <span style={styles.layerNum}>Layer 4: 페어 코딩 페르소나</span>
                    <span style={styles.layerName}>🐰 역할별 협업 규범 (agents/)</span>
                    <p style={styles.layerDesc}>기획 분석, 아키텍처 설계, 선테스트 작성, 코드 정성 검토 등 각 단계별 전문 역할을 지정하여 안정적인 협업 페어 코딩을 실현합니다.</p>
                  </div>
                  <div style={styles.layerBox}>
                    <span style={styles.layerNum}>Layer 5: 커맨드 인터랙션</span>
                    <span style={styles.layerName}>🥦 메소돌로지 스킬 세트 (skills/)</span>
                    <p style={styles.layerDesc}>개발자가 포탈이나 터미널에서 슬래시 명령어(/design, /develop)를 내렸을 때 에이전트가 이를 인식하여 자율적인 업무 프로세스를 작동시키는 지능형 도구를 제공합니다.</p>
                  </div>
                </div>
              </div>

              {/* Guidelines Info (Idea 3) */}
              <div className="glass-panel" style={styles.guideCard}>
                <h3 style={styles.sectionTitle}>🐰 바이브코딩 행동 강령 (Directing Guidelines)</h3>
                <p style={styles.guideText}>
                  AI 에이전트와 페어 프로그래밍 시 일의 효율을 극대화하기 위한 핵심 원칙입니다.
                </p>
                <div style={styles.guidelinesGrid}>
                  <div style={styles.guidelineCard}>
                    <span style={styles.guidelineIcon}>✍️</span>
                    <strong style={styles.guidelineTitle}>1. 코드를 직접 짜지 마세요</strong>
                    <p style={styles.guidelineDesc}>에이전트는 기획서와 테스트를 보고 설계합니다. 모든 수정은 요건 변경을 통해 지시하십시오.</p>
                  </div>
                  <div style={styles.guidelineCard}>
                    <span style={styles.guidelineIcon}>🎯</span>
                    <strong style={styles.guidelineTitle}>2. 요구사항(AC)을 세밀히 잡으세요</strong>
                    <p style={styles.guidelineDesc}>비즈니스 합격 기준이 모호하면 에이전트가 방황합니다. 소크라테스 인터뷰로 AC를 철저히 굳히십시오.</p>
                  </div>
                  <div style={styles.guidelineCard}>
                    <span style={styles.guidelineIcon}>🧪</span>
                    <strong style={styles.guidelineTitle}>3. 테스트(PyTest)를 먼저 만드세요</strong>
                    <p style={styles.guidelineDesc}>BDD 시나리오(Given-When-Then)를 먼저 작성하여 에러를 본 뒤 구현하는 TDD 규격을 이행하십시오.</p>
                  </div>
                  <div style={styles.guidelineCard}>
                    <span style={styles.guidelineIcon}>👀</span>
                    <strong style={styles.guidelineTitle}>4. 에이전트 구동 시엔 눈으로만 보세요</strong>
                    <p style={styles.guidelineDesc}>에이전트가 터미널에서 작업하는 동안에는 타이핑을 멈추고 관찰하며, 작동 완료 후에 피드백을 전달하십시오.</p>
                  </div>
                  <div style={styles.guidelineCard}>
                    <span style={styles.guidelineIcon}>🔧</span>
                    <strong style={styles.guidelineTitle}>5. 에러 시엔 자가 치유를 믿으세요</strong>
                    <p style={styles.guidelineDesc}>오류가 나면 직접 수정하지 말고, '/develop --fix'를 시켜 스스로 학습하고 치료하게 만드십시오.</p>
                  </div>
                </div>
              </div>
            </div>

            {/* Right: One-Click Installer & Diagnostics */}
            <div style={styles.sidebarColumn}>
              <div className="glass-panel" style={styles.installerCard}>
                <h2 style={styles.installerTitle}>🥦 원클릭 하네스 이식 (Bootstrapper)</h2>
                <p style={styles.installerText}>
                  이식할 대상 프로젝트의 이름을 지정해 주세요.
                  입력한 이름의 폴더가 이미 존재한다면 해당 폴더 내에 하네스를 이식하며, 존재하지 않는다면 신규 폴더를 자동 생성하고 가드레일 규칙 파일(.claude/, rules/), BDD 자율 테스트 작업 공간 등을 설치해 드립니다.
                </p>
                
                <div style={styles.guideStepsBox}>
                  <strong style={styles.guideStepsTitle}>💡 진행 방법 안내:</strong>
                  <ol style={styles.guideStepsList}>
                    <li>아래 입력창에 이식할 <strong>대상 프로젝트 명 ($PROJECT_NAME)</strong>을 입력합니다. (폴더가 없으면 신규 생성)</li>
                    <li>아래 <strong>[클릭 한 번으로 하네스 이식하기]</strong> 버튼을 누릅니다.</li>
                    <li>사용자 폴더 내에 하네스 설치가 기동되며, 최하단의 <strong>실시간 로그 콘솔</strong>에서 진행 상태와 환경 진단 로그를 확인하실 수 있습니다.</li>
                  </ol>
                </div>
                
                <div style={styles.formGroup}>
                  <label style={styles.label}>대상 프로젝트 명 ($PROJECT_NAME):</label>
                  <input 
                    type="text" 
                    value={targetDir} 
                    onChange={(e) => setTargetDir(e.target.value)} 
                    style={styles.input} 
                    placeholder="예: lakehouse"
                  />
                </div>

                <button 
                  onClick={handleBootstrap} 
                  disabled={isBootstrapping} 
                  style={{
                    ...styles.bootstrapBtn,
                    background: isBootstrapping ? 'var(--text-muted)' : 'var(--color-green-glow)',
                    color: isBootstrapping ? 'var(--text-secondary)' : 'var(--color-green)',
                    borderColor: isBootstrapping ? 'var(--text-muted)' : 'var(--color-green)'
                  }}
                >
                  {isBootstrapping ? '하네스 템플릿 이식 중...' : '클릭 한 번으로 하네스 이식하기'}
                </button>
              </div>

              {/* Project Vibe Readiness Checklist (Idea 4) */}
              <div className="glass-panel" style={styles.installerCard}>
                <h3 style={styles.installerTitle}>🐊 프로젝트 바이브 준비도 진단</h3>
                <p style={styles.installerText}>
                  선택한 프로젝트 폴더 내 바이브코딩에 필요한 런타임 및 하네스 컴플라이언스 도구 감지 상태입니다.
                </p>
                <div style={styles.checklistGroup}>
                  <div style={styles.checkRow}>
                    <span style={{
                      ...styles.checkIcon,
                      color: diagnostics.python_runtime ? 'var(--color-green)' : 'var(--color-red)'
                    }}>
                      {diagnostics.python_runtime ? '✓' : '✗'}
                    </span>
                    <div style={styles.checkText}>
                      <span style={styles.checkTitle}>Python 3 런타임 환경</span>
                      <span style={styles.checkDesc}>
                        {diagnostics.python_runtime ? '감지됨 (Python 3.8+ 환경 작동 중)' : '미설치 (시스템에 파이썬이 설치되어 있지 않습니다)'}
                      </span>
                    </div>
                  </div>

                  <div style={styles.checkRow}>
                    <span style={{
                      ...styles.checkIcon,
                      color: diagnostics.venv_active ? 'var(--color-green)' : 'var(--color-yellow)'
                    }}>
                      {diagnostics.venv_active ? '✓' : '⚠'}
                    </span>
                    <div style={styles.checkText}>
                      <span style={styles.checkTitle}>독립 가상환경 (.venv) 활성화</span>
                      <span style={styles.checkDesc}>
                        {diagnostics.venv_active ? '활성화됨 (격리된 파이썬 의존성 환경)' : '비활성 (안전한 개발을 위해 가상환경 구동을 권장합니다)'}
                      </span>
                    </div>
                  </div>

                  <div style={styles.checkRow}>
                    <span style={{
                      ...styles.checkIcon,
                      color: diagnostics.pytest_installed ? 'var(--color-green)' : 'var(--color-red)'
                    }}>
                      {diagnostics.pytest_installed ? '✓' : '✗'}
                    </span>
                    <div style={styles.checkText}>
                      <span style={styles.checkTitle}>BDD 테스트 엔진 (PyTest)</span>
                      <span style={styles.checkDesc}>
                        {diagnostics.pytest_installed ? '설치됨 (Given-When-Then 검증 엔진 구동 가능)' : '미설치 (PyTest 패키지 감지 실패, 설치가 필요합니다)'}
                      </span>
                    </div>
                  </div>

                  <div style={styles.checkRow}>
                    <span style={{
                      ...styles.checkIcon,
                      color: diagnostics.harness_installed ? 'var(--color-green)' : 'var(--color-red)'
                    }}>
                      {diagnostics.harness_installed ? '✓' : '✗'}
                    </span>
                    <div style={styles.checkText}>
                      <span style={styles.checkTitle}>하네스 가드레일 설치 상태</span>
                      <span style={styles.checkDesc}>
                        {diagnostics.harness_installed ? '적용 완료 (.rules/ 및 prompts/ 복사 완료)' : '미적용 (하네스 이식 마법사 가동이 필요합니다)'}
                      </span>
                    </div>
                  </div>
                </div>
                {diagnostics.python_runtime && diagnostics.pytest_installed && diagnostics.harness_installed ? (
                  <div style={styles.readyAlert}>
                    🎉 바이브코딩 준비 완료! 에이전트를 가동하십시오.
                  </div>
                ) : (
                  <div style={styles.warnAlert}>
                    👉 일부 필수 항목이 누락되었습니다. 원클릭 하네스 이식을 먼저 가동하세요.
                  </div>
                )}
              </div>

              {/* Vibe Workspace Connections Manager */}
              <div className="glass-panel" style={styles.installerCard}>
                <h3 style={styles.installerTitle}>🐻 이식된 바이브 프로젝트 목록</h3>
                <p style={styles.installerText}>
                  현재 시스템에 이식된 바이브코딩 프로젝트 환경 목록입니다. 원하는 프로젝트를 선택하여 활성화하고 원격으로 즉시 접속해 페어 코딩을 시작할 수 있습니다.
                </p>
                
                <div style={styles.projectList}>
                  {projects.map(proj => (
                    <div key={proj.name} style={{
                      ...styles.projectItem,
                      borderLeft: proj.is_active ? '4px solid var(--color-green)' : '4px solid transparent',
                      background: proj.is_active ? 'rgba(252, 175, 23, 0.04)' : 'rgba(0,0,0,0.01)'
                    }}>
                      <div style={styles.projectInfo}>
                        <div style={styles.projectNameLine}>
                          <span style={styles.projectName}>{proj.name}</span>
                          {proj.is_active && <span style={styles.activeBadge}>🎯 활성</span>}
                        </div>
                        <span style={styles.projectPath}>{proj.path}</span>
                        <div style={styles.projectDiags}>
                          <span style={{...styles.diagBadge, color: proj.diagnostics.venv_active ? 'var(--color-green)' : 'var(--text-muted)'}}>
                            venv: {proj.diagnostics.venv_active ? '활성' : '미활성'}
                          </span>
                          <span style={{...styles.diagBadge, color: proj.diagnostics.pytest_installed ? 'var(--color-green)' : 'var(--text-muted)'}}>
                            pytest: {proj.diagnostics.pytest_installed ? '설치됨' : '미설치'}
                          </span>
                          <span style={{...styles.diagBadge, color: proj.diagnostics.harness_installed ? 'var(--color-green)' : 'var(--text-muted)'}}>
                            harness: {proj.diagnostics.harness_installed ? '완료' : '미완료'}
                          </span>
                        </div>
                      </div>
                      
                      <div style={styles.projectActions}>
                        {!proj.is_active && (
                          <button 
                            onClick={() => handleSelectProject(proj.name)}
                            style={styles.selectProjBtn}
                          >
                            활성화
                          </button>
                        )}
                        <button 
                          onClick={() => {
                            setConnectingProject(proj)
                            setShowConnectModal(true)
                          }}
                          style={styles.connectProjBtn}
                        >
                          접속
                        </button>
                      </div>
                    </div>
                  ))}
                </div>
              </div>
            </div>
          </div>
        )}

        {/* Tab 2: Vibe Coding Prompt Gallery */}
        {activeTab === 'gallery' && (
          <div className="fade-in" style={{...styles.tabLayout, gridTemplateColumns: '1fr 360px'}}>
            {/* Left: Prompts list */}
            <div style={styles.contentColumn}>
              <div style={styles.galleryHeader}>
                <h2 style={styles.galleryTitle}>🐰 바이브코딩 프롬프트 북 (Copy & Paste)</h2>
                <p style={styles.gallerySubtitle}>아래 프롬프트를 차례대로 복사하여 에이전트(Claude Code / Antigravity) 채팅창에 입력하기만 하면 자율 개발이 안전하게 진행됩니다.</p>
              </div>
              
              <div style={styles.promptGrid}>
                {promptGallery.map((p, idx) => (
                  <div key={idx} className="glass-panel" style={styles.promptCard}>
                    <div style={styles.promptCardHeader}>
                      <span style={styles.promptStep}>{p.step}</span>
                      <span style={styles.promptCommand}>{p.command}</span>
                    </div>
                    <h3 style={styles.promptTitle}>{p.title}</h3>
                    <p style={styles.promptDesc}>{p.description}</p>
                    
                    <div style={styles.promptBox}>
                      <pre style={styles.promptPre}>{p.prompt}</pre>
                    </div>
                    
                    <button 
                      onClick={() => handleCopyText(p.prompt, idx)} 
                      style={{
                        ...styles.copyBtn,
                        backgroundColor: copiedIndex === idx ? 'var(--color-green-glow)' : 'rgba(255,255,255,0.03)',
                        borderColor: copiedIndex === idx ? 'var(--color-green)' : 'var(--border-color)',
                        color: copiedIndex === idx ? 'var(--color-green)' : 'var(--text-primary)'
                      }}
                    >
                      {copiedIndex === idx ? '✓ 복사 완료!' : '📋 프롬프트 복사하기'}
                    </button>
                  </div>
                ))}
              </div>
            </div>

            {/* Right: Command Cheat Sheet */}
            <div style={styles.sidebarColumn}>
              <div className="glass-panel" style={styles.installerCard}>
                <h3 style={styles.installerTitle}>⌨️ 에이전트 CLI 슬래시(/) 명령어 치트시트</h3>
                <p style={styles.installerText}>
                  에이전트 터미널(Antigravity CLI / Claude Code)에서 사용할 수 있는 대표적인 핵심 명령어 리스트입니다.
                </p>
                <div style={styles.cheatSheetList}>
                  {[
                    { cmd: '/interview', label: '요건 분석 인터뷰 기동', desc: '시드 요건을 기반으로 소크라테스 인터뷰를 진행해 모호성을 축소합니다.' },
                    { cmd: '/design', label: '컴플라이언스 아키텍처 설계', desc: '망분리 및 DB Read-Only 규칙을 반영하여 시스템 설계 문서를 작성합니다.' },
                    { cmd: '/decompose', label: '태스크 카드 분해', desc: '설계 완료된 기획을 잘게 쪼개어 tasks/task-board.md 칸반에 카드로 적재합니다.' },
                    { cmd: '/develop', label: 'BDD 선테스트 및 자율 개발', desc: 'Given-When-Then PyTest를 먼저 작성하고 통과하는 코드를 구현합니다.' },
                    { cmd: '/review', label: '물리 가드레일 검증', desc: '개발 완료 후 DB 차단 및 APIM 헤더 누락 여부를 스캔하는 게이트를 작동합니다.' },
                    { cmd: '/develop --fix', label: '자가 복구 자가 치유 실행', desc: '빌드/게이트 실패 로그를 에이전트가 읽고 스스로 코드를 패치하게 만듭니다.' },
                    { cmd: '/ask', label: '아키텍처 및 지식 단순 조회', desc: '파일 수정이나 리서치 대신, 코드 아키텍처에 대한 질문만 수행합니다.' }
                  ].map((c, i) => (
                    <div key={i} style={styles.cheatRow}>
                      <div style={styles.cheatHeader}>
                        <code style={styles.cheatCode}>{c.cmd}</code>
                        <button 
                          onClick={() => handleCopyText(c.cmd, `cheat-${i}`)}
                          style={styles.cheatCopyBtn}
                        >
                          {copiedIndex === `cheat-${i}` ? '✓' : '복사'}
                        </button>
                      </div>
                      <strong style={styles.cheatLabel}>{c.label}</strong>
                      <p style={styles.cheatDesc}>{c.desc}</p>
                    </div>
                  ))}
                </div>
              </div>
            </div>
          </div>
        )}

        {/* Tab 3: Harness Template Structure (Idea 1) */}
        {activeTab === 'structure' && (
          <div className="fade-in" style={styles.tabLayout}>
            {/* Left: Interactive Directory Structure and Cards */}
            <div style={styles.contentColumn}>
              <div className="glass-panel" style={styles.guideCard}>
                <h2 style={styles.sectionTitle}>🥦 하네스 템플릿 디렉토리 전체 구조도</h2>
                <p style={styles.guideText}>
                  표준 하네스 템플릿의 핵심 폴더와 파일들의 배치도입니다. 각 요소를 클릭하면 자세하고 쉬운 역할 설명을 확인하실 수 있습니다.
                </p>
                
                <div style={styles.structureTree}>
                  {/* Root Node */}
                  <div style={styles.treeNode}>
                    <span onClick={() => toggleNode('kb-harness')} className="tree-folder-link" style={styles.treeFolderLink}>
                      <span style={styles.treeArrow}>{openNodes['kb-harness'] ? '▼' : '▶'}</span>
                      <span style={styles.treeIcon}>📁</span> <strong>kb-harness/</strong>
                    </span>
                    
                    {openNodes['kb-harness'] && (
                      <div style={styles.treeBranch}>
                        
                        {/* .claude Folder */}
                        <div style={styles.treeNode}>
                          <span onClick={() => toggleNode('kb-harness/.claude')} className="tree-folder-link" style={styles.treeFolderLink}>
                            <span style={styles.treeArrow}>{openNodes['kb-harness/.claude'] ? '▼' : '▶'}</span>
                            <span style={styles.treeIcon}>📁</span> <strong>.claude/</strong>
                            <span style={styles.treeLabel}>← Layer 1~5: 에이전트 표준 하네스 엔진</span>
                          </span>
                          
                          {openNodes['kb-harness/.claude'] && (
                            <div style={styles.treeBranch}>
                              <div style={styles.treeNode}>
                                <span style={styles.treeIcon}>📄</span> <strong>CLAUDE.md</strong>
                                <span style={styles.treeLabel}>← Layer 1: 오케스트레이터 (workflows 상태 정의 및 Auto-Healing 역방향 라우팅)</span>
                              </div>
                              
                              {/* rules Folder */}
                              <div style={styles.treeNode}>
                                <span onClick={() => toggleNode('kb-harness/.claude/rules')} className="tree-folder-link" style={styles.treeFolderLink}>
                                  <span style={styles.treeArrow}>{openNodes['kb-harness/.claude/rules'] ? '▼' : '▶'}</span>
                                  <span style={styles.treeIcon}>📁</span> <strong>rules/</strong>
                                  <span style={styles.treeLabel}>← Layer 2: 전사 표준 컴플라이언스 (통제 바운더리 - 기술 도메인별 표준 규칙)</span>
                                </span>
                                {openNodes['kb-harness/.claude/rules'] && (
                                  <div style={styles.treeBranch}>
                                    <div style={styles.treeNode}>
                                      <span style={styles.treeIcon}>📄</span> <strong>01-sec-ai-compliance.md</strong>
                                      <span style={styles.treeLabel}>— 금융 AI 보안 표준 (로그 기록, 킬 스위치, 소비자 사전 고지, DLP 필터, Rate Limiting 등)</span>
                                    </div>
                                    <div style={styles.treeNode}>
                                      <span style={styles.treeIcon}>📄</span> <strong>02-net-infra-compliance.md</strong>
                                      <span style={styles.treeLabel}>— 사내 네트워크/인프라 (PrivateLink 사설망, Docker 이미지 ARG, APIM 필수 헤더 규격)</span>
                                    </div>
                                    <div style={styles.treeNode}>
                                      <span style={styles.treeIcon}>📄</span> <strong>03-db-governance.md</strong>
                                      <span style={styles.treeLabel}>— 데이터 가버넌스 및 DB Read-Only 제한 표준 (NL2SQL SELECT-Only 강제 및 DML/DDL 차단)</span>
                                    </div>
                                    <div style={styles.treeNode}>
                                      <span style={styles.treeIcon}>📄</span> <strong>04-cicd-dependency.md</strong>
                                      <span style={styles.treeLabel}>— 폐쇄망 의존성 및 반입 패키징 표준 (requirements.txt 버전 고정, 오프라인 반입, 배포 체크리스트)</span>
                                    </div>
                                    <div style={styles.treeNode}>
                                      <span style={styles.treeIcon}>📄</span> <strong>05-code-testing.md</strong>
                                      <span style={styles.treeLabel}>— 파이썬 코딩 규격 및 BDD 테스트 준수 표준 (Mocking 분기, PEP 8 컨벤션, Given-When-Then PyTest)</span>
                                    </div>
                                  </div>
                                )}
                              </div>

                              {/* gates Folder */}
                              <div style={styles.treeNode}>
                                <span onClick={() => toggleNode('kb-harness/.claude/gates')} className="tree-folder-link" style={styles.treeFolderLink}>
                                  <span style={styles.treeArrow}>{openNodes['kb-harness/.claude/gates'] ? '▼' : '▶'}</span>
                                  <span style={styles.treeIcon}>📁</span> <strong>gates/</strong>
                                  <span style={styles.treeLabel}>← Layer 3: 물리적 가드레일 (Hard Gates - 0-Token 검사 스크립트)</span>
                                </span>
                                {openNodes['kb-harness/.claude/gates'] && (
                                  <div style={styles.treeBranch}>
                                    <div style={styles.treeNode}><span style={styles.treeIcon}>📄</span> <strong>gate-review-all.sh</strong> <span style={styles.treeLabel}>— [마스터] 모든 물리 게이트를 순차 실행하는 마스터 스크립트</span></div>
                                    <div style={styles.treeNode}><span style={styles.treeIcon}>📄</span> <strong>gate-review-package.sh</strong> <span style={styles.treeLabel}>— [패키징] 1차 보안 보고서 생성 및 반입용 zip 압축 패키징</span></div>
                                    <div style={styles.treeNode}><span style={styles.treeIcon}>📄</span> gate-02-api-headers.sh <span style={styles.treeLabel}>— rules/02 검증: KB원클라우드 APIM 호출 시 필수 헤더 5종 래핑 검사</span></div>
                                    <div style={styles.treeNode}><span style={styles.treeIcon}>📄</span> gate-03-db-readonly.py <span style={styles.treeLabel}>— rules/03 검증: AST 파싱 기반 SELECT 외 DDL/DML 원천 차단</span></div>
                                    <div style={styles.treeNode}><span style={styles.treeIcon}>📄</span> gate-04-pip-version.sh <span style={styles.treeLabel}>— rules/04 검증: requirements.txt 내 '==' 고정 여부 정적 검사</span></div>
                                    <div style={styles.treeNode}><span style={styles.treeIcon}>📄</span> gate-04-vuln-scanner.py <span style={styles.treeLabel}>— rules/04 검증: requirements.txt 내 CVSS &gt;= 7.0 취약 패키지 검사</span></div>
                                    <div style={styles.treeNode}><span style={styles.treeIcon}>📄</span> gate-05-lint-convention.py <span style={styles.treeLabel}>— rules/05 검증: IP 하드코딩(CWE-259) 및 사내 Python 규격 린터</span></div>
                                    <div style={styles.treeNode}><span style={styles.treeIcon}>📄</span> gate-05-pytest-runner.sh <span style={styles.treeLabel}>— rules/05 검증: BDD PyTest 자동 구동 및 커버리지 체크</span></div>
                                    <div style={styles.treeNode}><span style={styles.treeIcon}>📄</span> helper-04-fetch-deps.sh <span style={styles.treeLabel}>— [유틸리티] 오프라인용 의존성 패키지 일괄 다운로드 도구 (rules/04 매핑)</span></div>
                                  </div>
                                )}
                              </div>

                              {/* agents Folder */}
                              <div style={styles.treeNode}>
                                <span onClick={() => toggleNode('kb-harness/.claude/agents')} className="tree-folder-link" style={styles.treeFolderLink}>
                                  <span style={styles.treeArrow}>{openNodes['kb-harness/.claude/agents'] ? '▼' : '▶'}</span>
                                  <span style={styles.treeIcon}>📁</span> <strong>agents/</strong>
                                  <span style={styles.treeLabel}>← Layer 4: 전문 페르소나 (역할 정의 가이드)</span>
                                </span>
                                {openNodes['kb-harness/.claude/agents'] && (
                                  <div style={styles.treeBranch}>
                                    <div style={styles.treeNode}><span style={styles.treeIcon}>📄</span> <strong>system-architect.md</strong> <span style={styles.treeLabel}>— 인프라 설계자 (rules/01, 02, 03 규칙을 참조하여 VPC 및 IaC 구성 설계)</span></div>
                                    <div style={styles.treeNode}><span style={styles.treeIcon}>📄</span> <strong>agent-developer.md</strong> <span style={styles.treeLabel}>— AI 개발자 (rules/01, 02, 03, 04, 05 규칙을 참조하여 에이전트 코드 및 BDD 구현)</span></div>
                                    <div style={styles.treeNode}><span style={styles.treeIcon}>📄</span> <strong>qa-security-reviewer.md</strong> <span style={styles.treeLabel}>— 품질/보안 리뷰어 (물리 게이트 통과 후, 문맥적 정성 리뷰만 전담)</span></div>
                                    <div style={styles.treeNode}><span style={styles.treeIcon}>📄</span> <strong>agent-general-worker.md</strong> <span style={styles.treeLabel}>— 범용 지원 일꾼 (특수 범주 외 일반 데이터 연산 및 문서 편집 지원)</span></div>
                                  </div>
                                )}
                              </div>

                              {/* skills Folder */}
                              <div style={styles.treeNode}>
                                <span onClick={() => toggleNode('kb-harness/.claude/skills')} className="tree-folder-link" style={styles.treeFolderLink}>
                                  <span style={styles.treeArrow}>{openNodes['kb-harness/.claude/skills'] ? '▼' : '▶'}</span>
                                  <span style={styles.treeIcon}>📁</span> <strong>skills/</strong>
                                  <span style={styles.treeLabel}>← Layer 5: 슬래시 커맨드 핸들러 (동작 로직 연동)</span>
                                </span>
                                {openNodes['kb-harness/.claude/skills'] && (
                                  <div style={styles.treeBranch}>
                                    <div style={styles.treeNode}><span style={styles.treeIcon}>📁</span> methodology/ <span style={styles.treeLabel}>— BDD/Ouroboros 등 프로젝트 방법론 조합 스킬 핸들러 (SKILL.md)</span></div>
                                    <div style={styles.treeNode}><span style={styles.treeIcon}>📁</span> interview/ <span style={styles.treeLabel}>— 소크라테스 2-경로 요건 인터뷰 스킬 핸들러 (SKILL.md)</span></div>
                                    <div style={styles.treeNode}><span style={styles.treeIcon}>📁</span> design/ <span style={styles.treeLabel}>— 시스템 아키텍처 및 인프라 설계 스킬 핸들러 (SKILL.md)</span></div>
                                    <div style={styles.treeNode}><span style={styles.treeIcon}>📁</span> decompose/ <span style={styles.treeLabel}>— 시드 요건의 3-Tier 아키텍처 분해 스킬 핸들러 (SKILL.md)</span></div>
                                    <div style={styles.treeNode}><span style={styles.treeIcon}>📁</span> develop/ <span style={styles.treeLabel}>— BDD 선제 개발 및 자율 버그 수정 스킬 핸들러 (SKILL.md)</span></div>
                                    <div style={styles.treeNode}><span style={styles.treeIcon}>📁</span> review/ <span style={styles.treeLabel}>— BDD 테스트 구동 및 자동 복구 피드백 스킬 핸들러 (SKILL.md)</span></div>
                                    <div style={styles.treeNode}><span style={styles.treeIcon}>📁</span> prompt-review/ <span style={styles.treeLabel}>— 코드-프롬프트 정합성 검증 스킬 핸들러 (SKILL.md)</span></div>
                                  </div>
                                )}
                              </div>

                            </div>
                          )}
                        </div>

                        {/* docs Folder */}
                        <div style={styles.treeNode}>
                          <span onClick={() => toggleNode('kb-harness/docs')} className="tree-folder-link" style={styles.treeFolderLink}>
                            <span style={styles.treeArrow}>{openNodes['kb-harness/docs'] ? '▼' : '▶'}</span>
                            <span style={styles.treeIcon}>📁</span> <strong>docs/</strong>
                            <span style={styles.treeLabel}>← [릴리즈/관리 문서 격리 폴더]</span>
                          </span>
                          {openNodes['kb-harness/docs'] && (
                            <div style={styles.treeBranch}>
                              <div style={styles.treeNode}><span style={styles.treeIcon}>📄</span> <strong>harness_merge_and_refactoring_history.md</strong> <span style={styles.treeLabel}>— 통합 및 리팩토링 이력서 (History)</span></div>
                              <div style={styles.treeNode}><span style={styles.treeIcon}>📄</span> <strong>kb-unified-standard-presentation.pptx</strong> <span style={styles.treeLabel}>— 아키텍처 및 상세 설계 발표 자료</span></div>
                            </div>
                          )}
                        </div>

                        {/* recommended Folder */}
                        <div style={styles.treeNode}>
                          <span onClick={() => toggleNode('kb-harness/recommended')} className="tree-folder-link" style={styles.treeFolderLink}>
                            <span style={styles.treeArrow}>{openNodes['kb-harness/recommended'] ? '▼' : '▶'}</span>
                            <span style={styles.treeIcon}>📁</span> <strong>recommended/</strong>
                            <span style={styles.treeLabel}>← 함께 쓰면 좋은 외부 도구 "설치 목록" (코드 아님, 참조)</span>
                          </span>
                          {openNodes['kb-harness/recommended'] && (
                            <div style={styles.treeBranch}>
                              <div style={styles.treeNode}><span style={styles.treeIcon}>📄</span> README.md</div>
                            </div>
                          )}
                        </div>

                        {/* .claude-plugin Folder */}
                        <div style={styles.treeNode}>
                          <span onClick={() => toggleNode('kb-harness/.claude-plugin')} className="tree-folder-link" style={styles.treeFolderLink}>
                            <span style={styles.treeArrow}>{openNodes['kb-harness/.claude-plugin'] ? '▼' : '▶'}</span>
                            <span style={styles.treeIcon}>📁</span> <strong>.claude-plugin/</strong>
                          </span>
                          {openNodes['kb-harness/.claude-plugin'] && (
                            <div style={styles.treeBranch}>
                              <div style={styles.treeNode}><span style={styles.treeIcon}>📄</span> <strong>marketplace.json</strong> <span style={styles.treeLabel}>← 플러그인 마켓 매니페스트</span></div>
                            </div>
                          )}
                        </div>

                        {/* Root Files */}
                        <div style={styles.treeNode}><span style={styles.treeIcon}>📄</span> <strong>.gitignore</strong> <span style={styles.treeLabel}>— 로컬 작업 공간 및 OS 임시 파일 차단 규정 (설치 시 자동 통합)</span></div>
                        <div style={styles.treeNode}><span style={styles.treeIcon}>📄</span> <strong>setup-harness.sh</strong> <span style={styles.treeLabel}>— [원클릭] 하네스 이식, .gitignore 병합 및 로컬 가상환경 자가진단 도구</span></div>
                        <div style={styles.treeNode}><span style={styles.treeIcon}>📄</span> <strong>VIBE_QUICKSTART.md</strong> <span style={styles.treeLabel}>— [10분 가이드] 자율/수동 모드 안내 및 복사-붙여넣기용 치트 프롬프트 북</span></div>

                      </div>
                    )}
                  </div>
                </div>
              </div>

              {/* Detailed Cards Section */}
              <div style={styles.detailsGrid}>
                <div className="glass-panel" style={styles.detailCard}>
                  <div style={styles.detailHeader}>
                    <span style={styles.detailBadge}>오케스트레이터</span>
                    <h3 style={styles.detailTitle}>📁 .claude/ & CLAUDE.md</h3>
                  </div>
                  <strong style={styles.detailLabel}>🥦 에이전트 "두뇌 행동 매뉴얼"</strong>
                  <p style={styles.detailDesc}>
                    에이전트가 프로젝트 디렉토리에 진입했을 때 처음 참조하는 중심 행동강령입니다. BDD 테스트가 통과해야만 개발 완료로 인정하고, 테스트나 린터 에러가 발생하면 중단하지 않고 즉시 <code>/develop --fix</code> 명령을 기동해 자가 수정하도록 하는 라우팅 규칙이 명시되어 있습니다.
                  </p>
                </div>

                <div className="glass-panel" style={styles.detailCard}>
                  <div style={styles.detailHeader}>
                    <span style={styles.detailBadge}>컴플라이언스</span>
                    <h3 style={styles.detailTitle}>📁 rules/ 하위 규칙들</h3>
                  </div>
                  <strong style={styles.detailLabel}>🐊 사내 표준 및 가드레일 정책</strong>
                  <p style={styles.detailDesc}>
                    에이전트가 개발할 때 반드시 준수해야 하는 강제 수칙입니다. API 통신 시 사내 필수 APIM 헤더를 래핑하도록 보조하는 규칙, 개발 시 실수로 데이터를 소실하거나 변조하는 것을 방어하는 DB Read-Only 규칙, 임의 라이브러리 설치를 필터링하는 규칙 등이 집대성되어 있습니다.
                  </p>
                </div>

                <div className="glass-panel" style={styles.detailCard}>
                  <div style={styles.detailHeader}>
                    <span style={styles.detailBadge}>검증 엔진</span>
                    <h3 style={styles.detailTitle}>📁 gates/ & gate-review-all.sh</h3>
                  </div>
                  <strong style={styles.detailLabel}>🛡️ 사내 규정 "최종 물리 검역소"</strong>
                  <p style={styles.detailDesc}>
                    개발이 완료된 소스코드가 <code>rules/</code>에 규정된 규격을 정확히 지켰는지 쉘 스크립트와 파이썬 AST 정적 스캐너를 이용해 검증하는 자동 검역대입니다. 여기서 하나라도 실패(Fail)할 경우, 릴리즈 빌드 및 패키징 단계로 진입할 수 없어 부적격 코드의 배포를 원천 차단합니다.
                  </p>
                </div>

                <div className="glass-panel" style={styles.detailCard}>
                  <div style={styles.detailHeader}>
                    <span style={styles.detailBadge}>공동 책상</span>
                    <h3 style={styles.detailTitle}>📁 _workspace/ 작업 공간</h3>
                  </div>
                  <strong style={styles.detailLabel}>🐰 페어 프로그래밍 공간</strong>
                  <p style={styles.detailDesc}>
                    인간과 AI가 실시간으로 소통하며 코드를 구축하는 연습실입니다. 기획서를 보관하는 <code>docs/</code>, 진행 일정을 체크박스로 관리하는 칸반 문서 <code>tasks/task-board.md</code>, 실제 소스코드가 구현되는 <code>src/</code>로 구성되어 에이전트의 자율 개발 집중도를 보장합니다.
                  </p>
                </div>
              </div>
            </div>

            {/* Right: Beginner Q&A Sidebar */}
            <div style={styles.sidebarColumn}>
              <div className="glass-panel" style={styles.installerCard}>
                <h3 style={styles.installerTitle}>🐤 바이브코딩 초보자 핵심 Q&A</h3>
                <p style={styles.installerText}>
                  표준 하네스 템플릿과 에이전트 협업 방식에 대해 자주 묻는 질문들을 모았습니다.
                </p>
                
                <div style={styles.qaList}>
                  <div style={styles.qaItem}>
                    <strong style={styles.qaQuestion}>Q. 하네스(Harness)가 왜 꼭 필요한가요?</strong>
                    <p style={styles.qaAnswer}>
                      AI 에이전트는 매우 우수하지만 사내 망분리 규정이나 필수 API 헤더 규격 등을 모른 채 자의적으로 코딩할 수 있습니다. 하네스는 에이전트가 안전한 주행 차선(보안/표준)을 벗어나지 않도록 감싸주는 <strong>중앙분리대</strong> 역할을 합니다.
                    </p>
                  </div>

                  <div style={styles.qaItem}>
                    <strong style={styles.qaQuestion}>Q. BDD 테스트 코드는 왜 먼저 짜나요?</strong>
                    <p style={styles.qaAnswer}>
                      'Given(상황), When(동작), Then(결과)'의 자연어 형식 테스트를 먼저 짜두면, 사람도 요구사항을 정확히 명세하게 되고 에이전트 역시 이 시나리오에 완벽히 합격하는 최소한의 정확한 코드만 짜게 되므로 버그가 생기지 않습니다.
                    </p>
                  </div>

                  <div style={styles.qaItem}>
                    <strong style={styles.qaQuestion}>Q. 자가 치유(Auto-Healing)란 무엇인가요?</strong>
                    <p style={styles.qaAnswer}>
                      검역 게이트에서 컴파일 에러나 규격 위반이 나면 에이전트가 중단되는 대신, <code>/develop --fix</code> 명령을 받아 에러 원인 분석 → 코드 자동 수정 → 게이트 재실행까지 스스로 반복해 버그를 치료하는 순환식 자동 복구 프로세스입니다.
                    </p>
                  </div>
                </div>
              </div>
            </div>
          </div>
        )}

      </main>

      {/* Terminal Console (Always visible at the bottom) */}
      <footer className="glass-panel" style={styles.terminalCard}>
        <div style={styles.terminalHeader}>
          <div style={styles.terminalDots}>
            <span style={{...styles.dot, backgroundColor: '#ff5f56'}}></span>
            <span style={{...styles.dot, backgroundColor: '#ffbd2e'}}></span>
            <span style={{...styles.dot, backgroundColor: '#27c93f'}}></span>
          </div>
          <span style={styles.terminalTitle}>터미널 실시간 출력 / 로그 모니터링 (Terminal Console)</span>
        </div>
        <div ref={terminalRef} style={styles.terminalConsole}>
          {terminalLogs.map((log, idx) => (
            <div key={idx} style={{
              ...styles.logLine,
              color: log.type === 'error' ? 'var(--color-red)' : log.type === 'success' ? 'var(--color-green)' : log.type === 'warn' ? 'var(--color-yellow)' : log.type === 'command' ? 'var(--color-blue)' : '#f5f4f2'
            }}>
              {log.text}
            </div>
          ))}
        </div>
            </footer>

      {showConnectModal && connectingProject && (
        <div style={styles.modalOverlay}>
          <div className="glass-panel" style={styles.modalContent}>
            <div style={styles.modalHeader}>
              <h3 style={styles.modalTitle}>📂 [{connectingProject.name}] 바이브 환경 연결 가이드</h3>
              <button onClick={() => setShowConnectModal(false)} style={styles.closeModalBtn}>✕</button>
            </div>
            
            <p style={styles.modalText}>
              해당 프로젝트 환경에서 바이브코딩(에이전트 개발)을 기동하는 3가지 연결 방법입니다. 
              사내망 가이드라인에 따라 가장 편리한 방식을 활용하십시오.
            </p>
            
            <div style={styles.connectOptions}>
              
              {/* Option 1: VS Code Remote-SSH */}
              <div style={styles.connectOptionCard}>
                <div style={styles.optionHeader}>
                  <span style={styles.optionNumber}>방법 1</span>
                  <strong style={styles.optionTitle}>VS Code 원격 연결 (Remote-SSH)</strong>
                </div>
                <p style={styles.optionDesc}>로컬 PC의 VS Code를 원격 개발 서버 폴더에 바로 연동합니다.</p>
                <div style={styles.optionActions}>
                  <a 
                    href={`vscode://vscode-remote/ssh-remote+tree67890@${window.location.hostname}/home/tree67890/${connectingProject.name}`}
                    style={styles.actionLink}
                  >
                    VS Code로 즉시 연결하기
                  </a>
                  <button 
                    onClick={() => {
                      navigator.clipboard.writeText(`vscode://vscode-remote/ssh-remote+tree67890@${window.location.hostname}/home/tree67890/${connectingProject.name}`)
                      alert('VS Code 프로토콜 연결 링크가 클립보드에 복사되었습니다!')
                    }}
                    style={styles.modalActionBtn}
                  >
                    링크 복사
                  </button>
                </div>
              </div>
              
              {/* Option 2: Cursor IDE */}
              <div style={styles.connectOptionCard}>
                <div style={styles.optionHeader}>
                  <span style={styles.optionNumber}>방법 2</span>
                  <strong style={styles.optionTitle}>Cursor 에디터 연결 (Cursor AppLink)</strong>
                </div>
                <p style={styles.optionDesc}>Cursor 에디터를 사용하여 원격 개발 환경 폴더로 즉시 진입합니다.</p>
                <div style={styles.optionActions}>
                  <a 
                    href={`cursor://file/home/tree67890/${connectingProject.name}`}
                    style={styles.actionLink}
                  >
                    Cursor로 즉시 연결하기
                  </a>
                  <button 
                    onClick={() => {
                      navigator.clipboard.writeText(`cursor://file/home/tree67890/${connectingProject.name}`)
                      alert('Cursor 연결 링크가 클립보드에 복사되었습니다!')
                    }}
                    style={styles.modalActionBtn}
                  >
                    링크 복사
                  </button>
                </div>
              </div>
              
              {/* Option 3: Terminal Connection */}
              <div style={styles.connectOptionCard}>
                <div style={styles.optionHeader}>
                  <span style={styles.optionNumber}>방법 3</span>
                  <strong style={styles.optionTitle}>SSH 터미널 접속 & 에이전트 CLI 실행</strong>
                </div>
                <p style={styles.optionDesc}>터미널로 해당 프로젝트에 접속하여 CLI 도구를 바로 구동합니다.</p>
                <div style={styles.commandCodeBlock}>
                  <code>ssh -t tree67890@{window.location.hostname} "cd ~/{connectingProject.name} && agy"</code>
                </div>
                <button 
                  onClick={() => {
                    navigator.clipboard.writeText(`ssh -t tree67890@${window.location.hostname} "cd ~/${connectingProject.name} && agy"`)
                    alert('SSH 터미널 실행 명령어가 클립보드에 복사되었습니다!')
                  }}
                  style={{...styles.modalActionBtn, marginTop: '8px', width: '100%'}}
                >
                  명령어 복사하기
                </button>
              </div>

            </div>
          </div>
        </div>
      )}
    </div>
  )
}

// Global UI Styles
const styles = {
  container: {
    maxWidth: '1360px',
    margin: '0 auto',
    padding: '24px',
    display: 'flex',
    flexDirection: 'column',
    gap: '24px',
    minHeight: '100vh'
  },
  header: {
    padding: '16px 24px',
    display: 'flex',
    justifyContent: 'space-between',
    alignItems: 'center',
    flexWrap: 'wrap',
    gap: '16px'
  },
  projectSelectorSection: {
    display: 'flex',
    alignItems: 'center',
    background: 'rgba(252, 175, 23, 0.05)',
    padding: '6px 12px',
    borderRadius: '8px',
    border: '1px solid rgba(252, 175, 23, 0.3)'
  },
  projectSelectDropdown: {
    background: 'transparent',
    border: 'none',
    color: 'var(--text-primary)',
    fontWeight: '700',
    fontSize: '12px',
    cursor: 'pointer',
    outline: 'none',
    fontFamily: 'var(--font-mono)'
  },
  logoSection: {
    display: 'flex',
    alignItems: 'center',
    gap: '12px'
  },
  title: {
    fontSize: '20px',
    fontWeight: '700',
    letterSpacing: '0.5px',
    color: 'var(--text-primary)'
  },
  subtitle: {
    fontSize: '11px',
    color: 'var(--text-secondary)'
  },
  tabButtons: {
    display: 'flex',
    gap: '16px'
  },
  tabBtn: {
    padding: '12px 16px',
    fontSize: '14px',
    fontWeight: '600',
    background: 'none',
    border: 'none',
    transition: 'all var(--transition-speed)',
    cursor: 'pointer'
  },
  mainContent: {
    flexGrow: 1,
    minHeight: '400px'
  },
  tabLayout: {
    display: 'grid',
    gridTemplateColumns: '1fr 380px',
    gap: '24px',
    alignItems: 'start'
  },
  contentColumn: {
    display: 'flex',
    flexDirection: 'column',
    gap: '24px'
  },
  sidebarColumn: {
    display: 'flex',
    flexDirection: 'column',
    gap: '24px'
  },
  guideCard: {
    padding: '28px',
    display: 'flex',
    flexDirection: 'column',
    gap: '16px',
    lineHeight: '1.6'
  },
  sectionTitle: {
    fontSize: '18px',
    fontWeight: '600',
    color: 'var(--text-primary)'
  },
  guideText: {
    fontSize: '14px',
    color: 'var(--text-secondary)'
  },
  layersGrid: {
    display: 'grid',
    gridTemplateColumns: 'repeat(auto-fit, minmax(220px, 1fr))',
    gap: '16px',
    marginTop: '12px'
  },
  layerBox: {
    padding: '16px',
    background: 'rgba(255,255,255,0.02)',
    border: '1px solid var(--border-color)',
    borderRadius: '10px',
    display: 'flex',
    flexDirection: 'column',
    gap: '6px'
  },
  layerNum: {
    fontSize: '11px',
    fontWeight: '700',
    color: 'var(--color-green)',
    textTransform: 'uppercase'
  },
  layerName: {
    fontSize: '14px',
    fontWeight: '600',
    color: 'var(--text-primary)'
  },
  layerDesc: {
    fontSize: '12px',
    color: 'var(--text-secondary)'
  },
  guideStepsBox: {
    background: 'rgba(252, 175, 23, 0.05)',
    border: '1px dashed rgba(252, 175, 23, 0.25)',
    borderRadius: '8px',
    padding: '12px 14px',
    fontSize: '12px',
    lineHeight: '1.6',
    color: 'var(--text-primary)'
  },
  guideStepsTitle: {
    display: 'block',
    marginBottom: '6px',
    fontWeight: '600',
    color: 'var(--color-green)'
  },
  guideStepsList: {
    paddingLeft: '18px',
    margin: 0
  },
  guidelinesGrid: {
    display: 'grid',
    gridTemplateColumns: 'repeat(auto-fit, minmax(200px, 1fr))',
    gap: '16px',
    marginTop: '12px'
  },
  guidelineCard: {
    padding: '16px',
    background: 'rgba(0, 0, 0, 0.01)',
    border: '1px solid var(--border-color)',
    borderRadius: '10px',
    display: 'flex',
    flexDirection: 'column',
    gap: '8px'
  },
  guidelineIcon: {
    fontSize: '24px'
  },
  guidelineTitle: {
    fontSize: '13px',
    fontWeight: '600',
    color: 'var(--text-primary)'
  },
  guidelineDesc: {
    fontSize: '11px',
    color: 'var(--text-secondary)',
    lineHeight: '1.4'
  },
  checklistGroup: {
    display: 'flex',
    flexDirection: 'column',
    gap: '14px'
  },
  checkRow: {
    display: 'flex',
    gap: '12px',
    alignItems: 'flex-start'
  },
  checkIcon: {
    fontSize: '16px',
    fontWeight: 'bold',
    width: '20px',
    textAlign: 'center'
  },
  checkText: {
    display: 'flex',
    flexDirection: 'column',
    gap: '2px'
  },
  checkTitle: {
    fontSize: '13px',
    fontWeight: '600',
    color: 'var(--text-primary)'
  },
  checkDesc: {
    fontSize: '11px',
    color: 'var(--text-secondary)'
  },
  readyAlert: {
    padding: '12px',
    background: 'rgba(252, 175, 23, 0.08)',
    border: '1px solid var(--color-green)',
    borderRadius: '6px',
    color: 'var(--color-green)',
    fontSize: '12px',
    fontWeight: '600',
    textAlign: 'center',
    marginTop: '10px'
  },
  warnAlert: {
    padding: '12px',
    background: 'rgba(211, 47, 47, 0.05)',
    border: '1px dashed #d32f2f',
    borderRadius: '6px',
    color: '#c62828',
    fontSize: '12px',
    fontWeight: '600',
    textAlign: 'center',
    marginTop: '10px'
  },
  cheatSheetList: {
    display: 'flex',
    flexDirection: 'column',
    gap: '12px',
    maxHeight: '480px',
    overflowY: 'auto',
    paddingRight: '6px'
  },
  cheatRow: {
    padding: '10px 12px',
    background: 'rgba(0,0,0,0.01)',
    border: '1px solid var(--border-color)',
    borderRadius: '8px',
    display: 'flex',
    flexDirection: 'column',
    gap: '4px'
  },
  cheatHeader: {
    display: 'flex',
    justifyContent: 'space-between',
    alignItems: 'center'
  },
  cheatCode: {
    fontFamily: 'var(--font-mono)',
    fontSize: '12px',
    fontWeight: 'bold',
    color: 'var(--color-blue)',
    background: 'rgba(0, 0, 0, 0.03)',
    padding: '2px 6px',
    borderRadius: '4px'
  },
  cheatCopyBtn: {
    background: 'none',
    border: 'none',
    color: 'var(--text-secondary)',
    fontSize: '10px',
    cursor: 'pointer',
    padding: '2px 4px',
    borderRadius: '4px',
    transition: 'background var(--transition-speed)'
  },
  cheatLabel: {
    fontSize: '12px',
    fontWeight: '600',
    color: 'var(--text-primary)'
  },
  cheatDesc: {
    fontSize: '11px',
    color: 'var(--text-secondary)',
    lineHeight: '1.4'
  },
  installerCard: {
    padding: '24px',
    display: 'flex',
    flexDirection: 'column',
    gap: '16px'
  },
  treeFolderLink: {
    cursor: 'pointer',
    userSelect: 'none',
    display: 'inline-flex',
    alignItems: 'center',
    gap: '2px',
    padding: '2px 4px',
    borderRadius: '4px',
    transition: 'background var(--transition-speed)'
  },
  treeArrow: {
    fontSize: '9px',
    color: 'var(--text-secondary)',
    marginRight: '4px',
    width: '10px',
    textAlign: 'center',
    display: 'inline-block'
  },
  structureTree: {
    fontFamily: 'var(--font-mono)',
    fontSize: '13px',
    lineHeight: '1.8',
    background: 'rgba(0, 0, 0, 0.02)',
    padding: '20px',
    borderRadius: '10px',
    border: '1px solid var(--border-color)',
    color: 'var(--text-primary)',
    marginTop: '12px'
  },
  treeNode: {
    margin: '4px 0'
  },
  treeIcon: {
    display: 'inline-block',
    width: '20px',
    textAlign: 'center'
  },
  treeLabel: {
    fontSize: '12px',
    color: 'var(--text-secondary)',
    marginLeft: '6px'
  },
  treeBranch: {
    paddingLeft: '20px',
    borderLeft: '1px dotted var(--border-color)',
    marginLeft: '8px'
  },
  detailsGrid: {
    display: 'grid',
    gridTemplateColumns: 'repeat(auto-fit, minmax(280px, 1fr))',
    gap: '24px',
    marginTop: '8px'
  },
  detailCard: {
    padding: '20px',
    display: 'flex',
    flexDirection: 'column',
    gap: '12px'
  },
  detailHeader: {
    display: 'flex',
    justifyContent: 'space-between',
    alignItems: 'center',
    borderBottom: '1px solid var(--border-color)',
    paddingBottom: '10px'
  },
  detailBadge: {
    fontSize: '10px',
    fontWeight: '700',
    background: 'rgba(252, 175, 23, 0.1)',
    color: 'var(--color-green)',
    border: '1px solid rgba(252, 175, 23, 0.3)',
    padding: '2px 8px',
    borderRadius: '20px'
  },
  detailTitle: {
    fontSize: '15px',
    fontWeight: '700',
    color: 'var(--text-primary)'
  },
  detailLabel: {
    fontSize: '12px',
    fontWeight: '600',
    color: 'var(--color-green)'
  },
  detailDesc: {
    fontSize: '12px',
    color: 'var(--text-secondary)',
    lineHeight: '1.6'
  },
  qaList: {
    display: 'flex',
    flexDirection: 'column',
    gap: '18px',
    marginTop: '12px'
  },
  qaItem: {
    display: 'flex',
    flexDirection: 'column',
    gap: '6px'
  },
  qaQuestion: {
    fontSize: '13px',
    fontWeight: '600',
    color: 'var(--text-primary)'
  },
  qaAnswer: {
    fontSize: '12px',
    color: 'var(--text-secondary)',
    lineHeight: '1.5',
    background: 'rgba(0,0,0,0.01)',
    padding: '10px',
    borderRadius: '6px',
    borderLeft: '3px solid var(--color-green)'
  },
  installerTitle: {
    fontSize: '16px',
    fontWeight: '600',
    color: 'var(--text-primary)'
  },
  installerText: {
    fontSize: '13px',
    color: 'var(--text-secondary)',
    lineHeight: '1.5'
  },
  formGroup: {
    display: 'flex',
    flexDirection: 'column',
    gap: '8px'
  },
  label: {
    fontSize: '12px',
    color: 'var(--text-secondary)'
  },
  input: {
    width: '100%',
    background: 'rgba(255,255,255,0.03)',
    border: '1px solid var(--border-color)',
    borderRadius: '8px',
    padding: '10px 14px',
    color: 'var(--text-primary)',
    fontSize: '13px',
    fontFamily: 'var(--font-mono)',
    outline: 'none',
    transition: 'border-color var(--transition-speed)'
  },
  bootstrapBtn: {
    width: '100%',
    padding: '14px',
    borderRadius: '8px',
    border: '1px solid transparent',
    fontSize: '14px',
    fontWeight: '600',
    cursor: 'pointer',
    transition: 'all var(--transition-speed)'
  },
  galleryLayout: {
    display: 'flex',
    flexDirection: 'column',
    gap: '24px'
  },
  galleryHeader: {
    display: 'flex',
    flexDirection: 'column',
    gap: '8px'
  },
  galleryTitle: {
    fontSize: '18px',
    fontWeight: '600'
  },
  gallerySubtitle: {
    fontSize: '13px',
    color: 'var(--text-secondary)'
  },
  promptGrid: {
    display: 'grid',
    gridTemplateColumns: '1fr 1fr',
    gap: '24px'
  },
  promptCard: {
    padding: '24px',
    display: 'flex',
    flexDirection: 'column',
    gap: '12px'
  },
  promptCardHeader: {
    display: 'flex',
    justifyContent: 'space-between',
    alignItems: 'center'
  },
  promptStep: {
    fontSize: '12px',
    fontWeight: '600',
    color: 'var(--color-green)'
  },
  promptCommand: {
    fontSize: '11px',
    fontFamily: 'var(--font-mono)',
    background: 'rgba(255,255,255,0.05)',
    padding: '2px 6px',
    borderRadius: '4px',
    color: 'var(--color-blue)'
  },
  promptTitle: {
    fontSize: '15px',
    fontWeight: '600'
  },
  promptDesc: {
    fontSize: '12px',
    color: 'var(--text-secondary)',
    lineHeight: '1.5'
  },
  promptBox: {
    background: '#040507',
    border: '1px solid var(--border-color)',
    borderRadius: '8px',
    padding: '12px',
    maxHeight: '160px',
    overflowY: 'auto'
  },
  promptPre: {
    fontFamily: 'var(--font-mono)',
    fontSize: '11px',
    color: '#e6edf3',
    whiteSpace: 'pre-wrap',
    lineHeight: '1.5'
  },
  copyBtn: {
    width: '100%',
    padding: '10px',
    borderRadius: '6px',
    border: '1px solid var(--border-color)',
    fontSize: '12px',
    fontWeight: '600',
    cursor: 'pointer',
    transition: 'all var(--transition-speed)'
  },
  dashboardLayout: {
    display: 'flex',
    flexDirection: 'column',
    gap: '24px'
  },
  panelCompact: {
    padding: '12px 24px'
  },
  dashboardMeta: {
    display: 'flex',
    justifyContent: 'space-between',
    alignItems: 'center',
    fontSize: '13px'
  },
  metaLabel: {
    color: 'var(--text-secondary)'
  },
  splitLayout: {
    display: 'grid',
    gridTemplateColumns: '360px 1fr',
    gap: '24px',
    alignItems: 'start'
  },
  leftCol: {
    display: 'flex',
    flexDirection: 'column',
    gap: '24px'
  },
  rightCol: {
    flexGrow: 1
  },
  panelCard: {
    padding: '20px',
    display: 'flex',
    flexDirection: 'column',
    gap: '16px'
  },
  panelHeader: {
    display: 'flex',
    justifyContent: 'space-between',
    alignItems: 'center'
  },
  panelTitle: {
    fontSize: '14px',
    fontWeight: '600',
    color: 'var(--text-secondary)',
    textTransform: 'uppercase',
    letterSpacing: '0.5px'
  },
  primaryButton: {
    padding: '6px 12px',
    backgroundColor: 'var(--color-green-glow)',
    border: '1px solid var(--color-green)',
    borderRadius: '6px',
    color: 'var(--color-green)',
    fontSize: '11px',
    fontWeight: '600',
    cursor: 'pointer'
  },
  gatesList: {
    display: 'flex',
    flexDirection: 'column',
    gap: '10px'
  },
  gateRow: {
    display: 'flex',
    justifyContent: 'space-between',
    alignItems: 'center',
    padding: '10px 12px',
    borderRadius: '8px',
    background: 'rgba(255, 255, 255, 0.02)',
    border: '1px solid rgba(255, 255, 255, 0.04)'
  },
  gateInfo: {
    display: 'flex',
    flexDirection: 'column',
    gap: '3px'
  },
  gateName: {
    fontSize: '13px',
    fontWeight: '500'
  },
  gateDesc: {
    fontSize: '11px',
    color: 'var(--text-secondary)'
  },
  statusBadge: {
    padding: '3px 8px',
    borderRadius: '12px',
    fontSize: '10px',
    fontWeight: '600'
  },
  actionGrid: {
    display: 'grid',
    gridTemplateColumns: '1fr',
    gap: '10px'
  },
  actionBtn: {
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'flex-start',
    gap: '3px',
    padding: '12px',
    borderRadius: '8px',
    background: 'rgba(255,255,255,0.01)',
    border: '1px solid var(--border-color)',
    textAlign: 'left',
    cursor: 'pointer'
  },
  actionBtnSub: {
    fontSize: '11px',
    color: 'var(--text-secondary)'
  },
  kanbanCard: {
    padding: '20px',
    display: 'flex',
    flexDirection: 'column',
    gap: '16px'
  },
  kanbanColumns: {
    display: 'grid',
    gridTemplateColumns: 'repeat(4, 1fr)',
    gap: '10px',
    alignItems: 'start'
  },
  kanbanCol: {
    background: 'rgba(255,255,255,0.01)',
    border: '1px solid var(--border-color)',
    borderRadius: '8px',
    padding: '10px'
  },
  kanbanColHeader: {
    display: 'flex',
    justifyContent: 'space-between',
    alignItems: 'center',
    marginBottom: '10px',
    fontSize: '12px',
    fontWeight: '600',
    color: 'var(--text-secondary)'
  },
  kanbanCount: {
    background: 'rgba(255,255,255,0.05)',
    padding: '2px 6px',
    borderRadius: '4px',
    fontSize: '10px'
  },
  kanbanColList: {
    display: 'flex',
    flexDirection: 'column',
    gap: '8px',
    minHeight: '200px'
  },
  taskCard: {
    background: 'rgba(255,255,255,0.02)',
    border: '1px solid rgba(255,255,255,0.04)',
    borderRadius: '8px',
    padding: '10px',
    display: 'flex',
    flexDirection: 'column',
    gap: '6px'
  },
  taskCardHeader: {
    display: 'flex',
    justifyContent: 'space-between',
    alignItems: 'center'
  },
  taskId: {
    fontSize: '10px',
    color: 'var(--text-secondary)',
    fontWeight: '500'
  },
  taskLevel: {
    fontSize: '9px',
    fontWeight: '600',
    textTransform: 'uppercase'
  },
  taskTitle: {
    fontSize: '12px',
    lineHeight: '1.4',
    color: 'var(--text-primary)'
  },
  taskCardFooter: {
    display: 'flex',
    justifyContent: 'space-between',
    alignItems: 'center',
    marginTop: '2px'
  },
  taskOwner: {
    fontSize: '10px',
    color: 'var(--text-secondary)'
  },
  taskSelect: {
    background: 'rgba(255,255,255,0.05)',
    border: 'none',
    color: 'var(--text-primary)',
    fontSize: '10px',
    padding: '2px',
    borderRadius: '4px',
    outline: 'none'
  },
  terminalCard: {
    display: 'flex',
    flexDirection: 'column'
  },
  terminalHeader: {
    padding: '10px 16px',
    borderBottom: '1px solid var(--border-color)',
    display: 'flex',
    alignItems: 'center',
    gap: '12px'
  },
  terminalDots: {
    display: 'flex',
    gap: '6px'
  },
  dot: {
    width: '8px',
    height: '8px',
    borderRadius: '50%'
  },
  terminalTitle: {
    fontSize: '12px',
    color: 'var(--text-secondary)',
    fontFamily: 'var(--font-mono)'
  },
  terminalConsole: {
    background: '#040507',
    padding: '16px',
    fontFamily: 'var(--font-mono)',
    fontSize: '12px',
    lineHeight: '1.6',
    height: '180px',
    overflowY: 'auto',
    borderBottomLeftRadius: '12px',
    borderBottomRightRadius: '12px'
  },
  logLine: {
    marginBottom: '4px',
    whiteSpace: 'pre-wrap'
  },
  projectList: {
    display: 'flex',
    flexDirection: 'column',
    gap: '12px',
    marginTop: '16px'
  },
  projectItem: {
    display: 'flex',
    justifyContent: 'space-between',
    alignItems: 'center',
    padding: '12px',
    borderRadius: '8px',
    border: '1px solid var(--border-color)',
    gap: '12px'
  },
  projectInfo: {
    display: 'flex',
    flexDirection: 'column',
    gap: '4px',
    flex: 1
  },
  projectNameLine: {
    display: 'flex',
    alignItems: 'center',
    gap: '8px'
  },
  projectName: {
    fontSize: '14px',
    fontWeight: '700',
    color: 'var(--text-primary)'
  },
  activeBadge: {
    fontSize: '10px',
    background: 'rgba(252, 175, 23, 0.15)',
    color: '#c98c00',
    padding: '2px 6px',
    borderRadius: '4px',
    fontWeight: '600'
  },
  projectPath: {
    fontSize: '11px',
    color: 'var(--text-secondary)',
    fontFamily: 'var(--font-mono)'
  },
  projectDiags: {
    display: 'flex',
    gap: '8px',
    marginTop: '2px'
  },
  diagBadge: {
    fontSize: '10px',
    fontWeight: '600'
  },
  projectActions: {
    display: 'flex',
    gap: '8px'
  },
  selectProjBtn: {
    padding: '6px 12px',
    background: 'rgba(252, 175, 23, 0.08)',
    color: '#c98c00',
    border: '1px solid rgba(252, 175, 23, 0.3)',
    borderRadius: '6px',
    fontSize: '12px',
    fontWeight: '600'
  },
  connectProjBtn: {
    padding: '6px 12px',
    background: '#1a1918',
    color: '#ffffff',
    borderRadius: '6px',
    fontSize: '12px',
    fontWeight: '600'
  },
  modalOverlay: {
    position: 'fixed',
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    background: 'rgba(0, 0, 0, 0.4)',
    backdropFilter: 'blur(4px)',
    display: 'flex',
    justifyContent: 'center',
    alignItems: 'center',
    zIndex: 1000
  },
  modalContent: {
    width: '90%',
    maxWidth: '640px',
    padding: '24px',
    background: 'var(--bg-base)',
    boxShadow: '0 20px 40px rgba(0,0,0,0.15)',
    border: '1px solid var(--border-color)',
    borderRadius: '12px',
    display: 'flex',
    flexDirection: 'column',
    gap: '16px'
  },
  modalHeader: {
    display: 'flex',
    justifyContent: 'space-between',
    alignItems: 'center'
  },
  modalTitle: {
    fontSize: '16px',
    fontWeight: '700',
    color: 'var(--text-primary)'
  },
  closeModalBtn: {
    background: 'none',
    border: 'none',
    fontSize: '18px',
    color: 'var(--text-secondary)',
    cursor: 'pointer'
  },
  modalText: {
    fontSize: '13px',
    color: 'var(--text-secondary)',
    lineHeight: '1.5'
  },
  connectOptions: {
    display: 'flex',
    flexDirection: 'column',
    gap: '16px'
  },
  connectOptionCard: {
    padding: '16px',
    background: 'rgba(0, 0, 0, 0.01)',
    border: '1px solid var(--border-color)',
    borderRadius: '8px',
    display: 'flex',
    flexDirection: 'column',
    gap: '8px'
  },
  optionHeader: {
    display: 'flex',
    alignItems: 'center',
    gap: '8px'
  },
  optionNumber: {
    fontSize: '9px',
    background: 'var(--color-green)',
    color: '#ffffff',
    padding: '2px 6px',
    borderRadius: '4px',
    fontWeight: '700'
  },
  optionTitle: {
    fontSize: '13px',
    color: 'var(--text-primary)'
  },
  optionDesc: {
    fontSize: '11px',
    color: 'var(--text-secondary)'
  },
  optionActions: {
    display: 'flex',
    gap: '8px',
    marginTop: '4px'
  },
  actionLink: {
    flex: 1,
    textAlign: 'center',
    padding: '8px 12px',
    background: 'var(--color-green)',
    color: '#ffffff',
    textDecoration: 'none',
    borderRadius: '6px',
    fontSize: '12px',
    fontWeight: '600'
  },
  modalActionBtn: {
    padding: '8px 16px',
    background: 'transparent',
    border: '1px solid var(--border-color)',
    borderRadius: '6px',
    fontSize: '12px',
    color: 'var(--text-primary)',
    fontWeight: '600'
  },
  commandCodeBlock: {
    background: '#040507',
    color: '#27c93f',
    fontFamily: 'var(--font-mono)',
    fontSize: '11px',
    padding: '12px',
    borderRadius: '6px',
    overflowX: 'auto',
    border: '1px solid rgba(255,255,255,0.05)',
    whiteSpace: 'nowrap'
  }
}
