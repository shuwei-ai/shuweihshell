import localUnitTest from './LocalUnit.test';
import wechatStylerTest from './WechatStyler.test';
import harnessComponentsTest from './HarnessComponents.test';
import superAgentTest from './SuperAgent.test';
import runCodeToolTest from './RunCodeTool.test';
import strictRouterIsolationTest from './StrictRouterIsolation.test';
import ticketStateMachineTest from './TicketStateMachine.test';
import asyncDispatchWaitOnTest from './AsyncDispatchWaitOn.test';
import inlineSpillAntiLoopTest from './InlineSpillAntiLoop.test';

export default function testsuite() {
  localUnitTest();
  wechatStylerTest();
  harnessComponentsTest();
  superAgentTest();
  runCodeToolTest();
  strictRouterIsolationTest();
  ticketStateMachineTest();
  asyncDispatchWaitOnTest();
  inlineSpillAntiLoopTest();
}

