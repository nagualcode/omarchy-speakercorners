import QtQuick 2.15
import QtTest 1.3

TestCase {
  name: "CornerMiradorModes"

  function speakercornersSource() {
    var request = new XMLHttpRequest()
    request.open("GET", Qt.resolvedUrl("../../Speakercorners.qml"), false)
    request.send()
    verify(request.status === 0 || request.status === 200)
    return request.responseText
  }

  function test_cornerTriggerRoutesToTheCurrentWorkspaceViewer() {
    var source = speakercornersSource()

    verify(/function\s+triggerMirador\(edge\)/.test(source),
      "Speakercorners must expose triggerMirador(edge)")
    verify(/if\s*\(edge\s*===\s*"bottom-right"\)[\s\S]*?root\.toggleMiradorWindows\(\)/.test(source),
      "Bottom-right corner must toggle the current-workspace window viewer")
    verify(/else\s*root\.toggleMirador\(\)/.test(source),
      "Other edges/entry points must keep the plain toggle behavior")
    verify(/case\s*"mirador":\s*root\.triggerMirador\(edge\)/.test(source),
      "Corner action must route the mirador target through triggerMirador")
  }

  function test_cornerTogglesOpenAndClose() {
    var source = speakercornersSource()
    var match = source.match(/function\s+toggleMiradorWindows\(\)\s*\{[\s\S]*?\n  \}/)
    verify(match !== null, "Speakercorners must expose toggleMiradorWindows()")
    var body = match[0]

    // Closed → open straight into the current-workspace viewer.
    verify(/!mirador\.opened[\s\S]*root\.openMiradorSingle\(\)/.test(body),
      "Closed overview must open the current-workspace viewer")
    // Open in that presentation → close it.
    verify(/mirador\.activePresentation\s*===\s*"single"[\s\S]*mirador\.dismiss\(\)/.test(body),
      "The viewer must close on the next trigger")
    // Open in another presentation → switch in place instead of stacking.
    verify(/mirador\.setPresentation\("single"\)/.test(body),
      "Another open presentation must switch in place to the current-workspace viewer")
    // There is no promotion to the full multi-workspace overview any more.
    verify(!/setPresentation\("full"\)/.test(body),
      "The corner must not promote the viewer to the full overview")
  }

  function test_openSingleUsesSinglePresentationPayload() {
    var source = speakercornersSource()
    var match = source.match(/function\s+openMiradorSingle\(\)\s*\{[\s\S]*?\n  \}/)
    verify(match !== null, "Speakercorners must expose openMiradorSingle()")
    verify(/presentation/.test(match[0]) && /"single"/.test(match[0]),
      "openMiradorSingle() must summon the current-workspace viewer")
  }

  function test_miradorIpcExposesCycleAndDiagnose() {
    var source = speakercornersSource()
    var target = source.indexOf('target: "mirador"')
    verify(target !== -1, "Speakercorners must register a mirador IpcHandler")
    var cycle = source.indexOf('function cycle(): string { root.toggleMiradorWindows(); return "ok" }')
    verify(cycle > target && /function[\s\S]{0,140}cycle[\s\S]{0,140}root\.toggleMiradorWindows\(\)/.test(source.slice(target, target + 600)),
      "mirador IPC must expose cycle() driving the same toggle as the corner")
    var diagnose = source.indexOf('function diagnose()')
    verify(diagnose > target && /activePresentation/.test(source.slice(target, diagnose + 500)),
      "mirador IPC must expose diagnose() reporting opened/presentation")
  }
}
