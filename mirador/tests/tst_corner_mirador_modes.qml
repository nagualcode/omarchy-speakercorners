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

  function test_cornerTriggerDispatchesToCycleStateMachine() {
    var source = speakercornersSource()

    verify(/function\s+triggerMirador\(edge\)/.test(source),
      "Speakercorners must expose triggerMirador(edge)")
    verify(/if\s*\(edge\s*===\s*"bottom-right"\)[\s\S]*?root\.cycleMirador\(\)/.test(source),
      "Bottom-right corner must drive the mode cycle")
    verify(/else\s*root\.toggleMirador\(\)/.test(source),
      "Other edges/entry points must keep the plain toggle behavior")
    verify(/case\s*"mirador":\s*root\.triggerMirador\(edge\)/.test(source),
      "Corner action must route the mirador target through triggerMirador")
  }

  function test_cycleStateMachineSingleToFullToClose() {
    var source = speakercornersSource()
    var match = source.match(/function\s+cycleMirador\(\)\s*\{[\s\S]*?\n  \}/)
    verify(match !== null, "Speakercorners must expose cycleMirador()")
    var body = match[0]

    // Closed → open straight into mode "1" (single current workspace).
    verify(/!mirador\.opened[\s\S]*root\.openMiradorSingle\(\)/.test(body),
      "Closed overview must open into mode 1 (single)")
    // Mode "1" → promote in place to mode "2" (full multi-workspace overview).
    verify(/mirador\.activePresentation\s*===\s*"single"[\s\S]*mirador\.setPresentation\("full"\)/.test(body),
      "Mode 1 must promote to mode 2 without tearing down the overlay")
    // Mode "2" → dismiss (and the whole chain ends with the dismiss call).
    verify(/mirador\.dismiss\(\)/.test(body) && body.indexOf("dismiss()") > body.indexOf("setPresentation(\"full\")"),
      "Trigger 3 must close the overview")
  }

  function test_openSingleUsesSinglePresentationPayload() {
    var source = speakercornersSource()
    var match = source.match(/function\s+openMiradorSingle\(\)\s*\{[\s\S]*?\n  \}/)
    verify(match !== null, "Speakercorners must expose openMiradorSingle()")
    verify(/presentation/.test(match[0]) && /"single"/.test(match[0]),
      "openMiradorSingle() must summon the summary view in mode 1")
  }
}