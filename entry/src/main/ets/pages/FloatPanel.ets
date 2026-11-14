/*
 * FloatPanel: The interactive UI loaded inside the native TYPE_FLOAT window.
 * Floats above any HarmonyOS application (WeChat, Browser, Settings, Launcher)
 * showing live Agent thought stream, tool execution, and active background worker tickets.
 */
import promptAction from '@ohos.promptAction';
import hilog from '@ohos.hilog';
import { FloatWindowManager } from '../window/FloatWindowManager';
import { AgentSession } from '../agent/AgentSession';
import { Ticket, TicketStepLog, WorkerRole, TicketEngine, TicketStore, AttentionManager } from '../agent';

@Entry
@Component
struct FloatPanel {
  @StorageProp('agentIsRunning') isRunning: boolean = false;
  @StorageProp('agentStatusText') statusText: string = '待命';
  @StorageProp('agentThinkingText') thinkingText: string = '';
  @StorageProp('agentCurrentTool') currentTool: string = '';
  @StorageProp('agentLatestPrompt') latestPrompt: string = '';
  @StorageProp('floatWindowCompact') isCompact: boolean = false;
  @StorageProp('activeTicketsCount') activeTicketsCount: number = 0;
  @StorageProp('activeTickets') activeTickets: Ticket[] = [];
  @State private expandedTicketId: string = '';

  private lastTouchScreenX: number = 0;
  private lastTouchScreenY: number = 0;
  private thoughtScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    const active = TicketStore.getInstance().getActiveTickets();
    if (active) {
      this.activeTickets = active;
      this.activeTicketsCount = active.length;
    }
  }

  build() {
    Column() {
      if (this.isCompact) {
        this.buildCompactPill()
      } else {
        this.buildExpandedPanel()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#00000000') // Parent must be transparent
    .justifyContent(FlexAlign.Start)
    .alignItems(HorizontalAlign.Center)
  }

  // Compact Pill View (e.g. 220vp x 54vp)
  @Builder
  buildCompactPill() {
    Row({ space: 8 }) {
      // Drag handle
      Text('⋮⋮')
        .fontSize(14)
        .fontColor('#94a3b8')
        .fontWeight(FontWeight.Bold)

      // Live pulse dot
      Circle({ width: 8, height: 8 })
        .fill(this.getCompactPulseColor())

      // Label
      Column({ space: 1 }) {
        Row({ space: 4 }) {
          Text('Pi Agent')
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor('#ffffff')

          if (this.activeTicketsCount > 0) {
            Text(`${this.activeTicketsCount}`)
              .fontSize(9)
              .fontWeight(FontWeight.Bold)
              .fontColor('#ffffff')
              .backgroundColor(this.hasWaitingHumanTicket() ? '#f59e0b' : '#0284c7')
              .borderRadius(6)
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          }
        }
        .alignItems(VerticalAlign.Center)

        Text(this.getCompactStatusText())
          .fontSize(10)
          .fontColor(this.hasWaitingHumanTicket() ? '#fcd34d' : '#cbd5e1')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // Expand button
      Button('展开')
        .fontSize(10)
        .height(24)
        .backgroundColor('#334155')
        .fontColor('#38bdf8')
        .borderRadius(12)
        .padding({ left: 8, right: 8 })
        .onClick(() => {
          FloatWindowManager.getInstance().setCompactMode(false);
        })

      // Back to App button
      Button('🔲')
        .fontSize(10)
        .height(24)
        .backgroundColor('#334155')
        .fontColor('#ffffff')
        .borderRadius(12)
        .padding({ left: 6, right: 6 })
        .onClick(() => {
          FloatWindowManager.getInstance().bringAppToForeground();
        })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 10, right: 10 })
    .backgroundColor('#0f172ae6') // Glass dark
    .borderRadius(27)
    .border({
      width: 1.5,
      color: this.hasWaitingHumanTicket()
        ? '#f59e0b'
        : ((this.isRunning || this.activeTicketsCount > 0) ? '#22c55e' : '#38bdf8')
    })
    .shadow({ radius: 12, color: '#66000000', offsetX: 0, offsetY: 4 })
    .onTouch((event: TouchEvent) => {
      this.handleWindowDrag(event);
    })
  }

  // Expanded Console View
  @Builder
  buildExpandedPanel() {
    Column() {
      // Header & Drag Area
      Row() {
        // Drag Indicator & Title
        Row({ space: 6 }) {
          Text('⋮⋮')
            .fontSize(14)
            .fontColor('#94a3b8')
            .fontWeight(FontWeight.Bold)

          Text('🤖 Pi Agent 悬浮窗')
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor('#ffffff')

          // Status Badge
          Row({ space: 4 }) {
            Circle({ width: 6, height: 6 })
              .fill(this.hasWaitingHumanTicket() ? '#f59e0b' : (this.isRunning || this.activeTicketsCount > 0 ? '#22c55e' : '#94a3b8'))
            Text(this.hasWaitingHumanTicket()
              ? '待确认'
              : (this.isRunning
                ? '执行中'
                : (this.activeTicketsCount > 0 ? `${this.activeTicketsCount} 专员` : '就绪')))
              .fontSize(9)
              .fontColor(this.hasWaitingHumanTicket()
                ? '#fde68a'
                : (this.isRunning || this.activeTicketsCount > 0 ? '#86efac' : '#cbd5e1'))
          }
          .padding({ left: 5, right: 5, top: 2, bottom: 2 })
          .backgroundColor(this.hasWaitingHumanTicket()
            ? '#78350f80'
            : (this.isRunning || this.activeTicketsCount > 0 ? '#14532d80' : '#33415580'))
          .borderRadius(8)
        }
        .alignItems(VerticalAlign.Center)
        .layoutWeight(1)

        // Window Controls
        Row({ space: 6 }) {
          // Pill Minimize
          Button('─')
            .fontSize(12)
            .height(24)
            .width(28)
            .backgroundColor('#1e293b')
            .fontColor('#94a3b8')
            .borderRadius(6)
            .padding(0)
            .onClick(() => {
              FloatWindowManager.getInstance().setCompactMode(true);
            })

          // Fullscreen Restore
          Button('🔲')
            .fontSize(11)
            .height(24)
            .width(28)
            .backgroundColor('#1e293b')
            .fontColor('#38bdf8')
            .borderRadius(6)
            .padding(0)
            .onClick(() => {
              FloatWindowManager.getInstance().bringAppToForeground();
            })

          // Close Floating Window
          Button('✕')
            .fontSize(11)
            .height(24)
            .width(28)
            .backgroundColor('#1e293b')
            .fontColor('#f87171')
            .borderRadius(6)
            .padding(0)
            .onClick(() => {
              FloatWindowManager.getInstance().hideFloatWindow();
            })
        }
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 8 })
      .backgroundColor('#0f172af0')
      .border({ width: { bottom: 1 }, color: '#334155' })
      .onTouch((event: TouchEvent) => {
        this.handleWindowDrag(event);
      })

      // Main Status / Thought / Tool Section
      Scroll(this.thoughtScroller) {
        Column({ space: 8 }) {
          // Latest Task Prompt Banner (if any)
          if (this.latestPrompt) {
            Row({ space: 6 }) {
              Text('🎯')
                .fontSize(11)
              Text(this.latestPrompt)
                .fontSize(11)
                .fontColor('#e2e8f0')
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
            }
            .width('100%')
            .padding({ left: 8, right: 8, top: 6, bottom: 6 })
            .backgroundColor('#1e293b99')
            .borderRadius(8)
          }

          // Active Tool Call Status Banner
          if (this.currentTool) {
            Row({ space: 6 }) {
              LoadingProgress()
                .width(14)
                .height(14)
                .color('#38bdf8')
              Text(this.currentTool)
                .fontSize(11)
                .fontWeight(FontWeight.Medium)
                .fontColor('#38bdf8')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
            }
            .width('100%')
            .padding({ left: 8, right: 8, top: 5, bottom: 5 })
            .backgroundColor('#0369a133')
            .border({ width: 1, color: '#0284c766' })
            .borderRadius(6)
          }

          // Active Background Workers List (F13 Wait-On in Float Window)
          if (this.activeTickets && this.activeTickets.length > 0) {
            this.buildActiveWorkersList()
          }

          // Live Reasoning / Thought Stream
          if (this.thinkingText) {
            Column({ space: 4 }) {
              Row({ space: 4 }) {
                Text('💭 实时思考')
                  .fontSize(10)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#94a3b8')
                Blank()
                Text(`${this.thinkingText.length} 字`)
                  .fontSize(9)
                  .fontColor('#64748b')
              }
              .width('100%')

              Text(this.thinkingText)
                .fontSize(11)
                .fontColor('#cbd5e1')
                .lineHeight(16)
                .fontFamily('monospace')
            }
            .width('100%')
            .padding(8)
            .backgroundColor('#1e293b66')
            .borderRadius(8)
          } else if (!this.currentTool && !this.isRunning && (!this.activeTickets || this.activeTickets.length === 0)) {
            Column({ space: 6 }) {
              Text('Agent 正在后台待命')
                .fontSize(12)
                .fontColor('#94a3b8')
              Text('跨应用执行任务时将在此实时展示思考与工具状态')
                .fontSize(10)
                .fontColor('#64748b')
            }
            .width('100%')
            .padding({ top: 16, bottom: 16 })
            .alignItems(HorizontalAlign.Center)
          }
        }
        .width('100%')
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })

      // Bottom Action Bar
      Row({ space: 8 }) {
        if (this.isRunning || this.activeTicketsCount > 0) {
          Button(this.activeTicketsCount > 0 ? `⏹ 停止所有任务 (${this.activeTicketsCount})` : '⏹ 停止任务')
            .fontSize(11)
            .height(28)
            .layoutWeight(1)
            .backgroundColor('#ef4444')
            .fontColor('#ffffff')
            .borderRadius(6)
            .onClick(() => {
              this.stopAgentTask();
            })
        } else {
          Button('🔲 返回全屏主界面')
            .fontSize(11)
            .height(28)
            .layoutWeight(1)
            .backgroundColor('#0284c7')
            .fontColor('#ffffff')
            .borderRadius(6)
            .onClick(() => {
              FloatWindowManager.getInstance().bringAppToForeground();
            })
        }
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 6, bottom: 8 })
      .backgroundColor('#0f172af8')
      .border({ width: { top: 1 }, color: '#334155' })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0f172af5') // Deep slate backdrop
    .borderRadius(16)
    .border({ width: 1.5, color: '#38bdf888' })
    .shadow({ radius: 18, color: '#88000000', offsetX: 0, offsetY: 6 })
    .clip(true)
  }

  // Active Background Workers Section (Wait-On in Float Window)
  @Builder
  buildActiveWorkersList() {
    Column({ space: 6 }) {
      // Header with count and abort all button
      Row() {
        Row({ space: 4 }) {
          Text('⚡ 后台专员任务')
            .fontSize(11)
            .fontWeight(FontWeight.Bold)
            .fontColor('#38bdf8')

          Text(`${this.activeTickets.length}`)
            .fontSize(10)
            .fontColor('#ffffff')
            .backgroundColor('#0284c7')
            .borderRadius(8)
            .padding({ left: 5, right: 5, top: 1, bottom: 1 })
        }

        Blank()

        Button('全部中断')
          .fontSize(9)
          .height(20)
          .backgroundColor('#ef444422')
          .fontColor('#f87171')
          .border({ width: 1, color: '#ef444455' })
          .borderRadius(4)
          .padding({ left: 6, right: 6 })
          .onClick(() => {
            TicketEngine.getInstance().abortAll();
            promptAction.showToast({ message: '已中断所有后台专员任务', duration: 1500 });
          })
      }
      .width('100%')

      // List of active tickets
      ForEach(this.activeTickets, (ticket: Ticket) => {
        Column({ space: 4 }) {
          // Top row: Role tag + Title + Status + Abort
          Row({ space: 6 }) {
            // Role tag
            Text(this.formatRoleName(ticket.role))
              .fontSize(9)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.getRoleTagColor(ticket.role))
              .backgroundColor(this.getRoleTagBgColor(ticket.role))
              .borderRadius(4)
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })

            // Title
            Text(ticket.title)
              .fontSize(11)
              .fontWeight(FontWeight.Medium)
              .fontColor('#ffffff')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)

            // Status Badge
            if (ticket.status === 'WaitingHuman') {
              Text('⚠️ 待确认')
                .fontSize(9)
                .fontColor('#fde68a')
                .backgroundColor('#78350f')
                .borderRadius(4)
                .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            } else {
              Text('运行中')
                .fontSize(9)
                .fontColor('#86efac')
                .backgroundColor('#14532d')
                .borderRadius(4)
                .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            }

            // Expand Details Button
            Button(this.expandedTicketId === ticket.id ? '收起 ▲' : '详情 ▼')
              .fontSize(9)
              .height(18)
              .backgroundColor('#334155')
              .fontColor('#38bdf8')
              .borderRadius(4)
              .padding({ left: 5, right: 5 })
              .onClick(() => {
                if (this.expandedTicketId === ticket.id) {
                  this.expandedTicketId = '';
                } else {
                  this.expandedTicketId = ticket.id;
                }
              })

            // Single Abort Button
            Button('中断')
              .fontSize(9)
              .height(18)
              .backgroundColor('#334155')
              .fontColor('#f87171')
              .borderRadius(4)
              .padding({ left: 5, right: 5 })
              .onClick(() => {
                TicketEngine.getInstance().abortTicket(ticket.id);
                promptAction.showToast({ message: `已中断任务: ${ticket.title}`, duration: 1500 });
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          // Progress text & progress bar
          if (ticket.progress) {
            Row({ space: 4 }) {
              Text(ticket.progress.actionText || '执行中...')
                .fontSize(10)
                .fontColor('#94a3b8')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)

              Text(`${ticket.progress.currentStep}/${ticket.progress.maxSteps}`)
                .fontSize(9)
                .fontColor('#64748b')
            }
            .width('100%')

            Progress({
              value: ticket.progress.currentStep,
              total: ticket.progress.maxSteps,
              type: ProgressType.Linear
            })
              .width('100%')
              .height(3)
              .color(ticket.status === 'WaitingHuman' ? '#f59e0b' : '#38bdf8')
              .backgroundColor('#1e293b')
          }

          // Expanded Details in Float Window
          if (this.expandedTicketId === ticket.id) {
            Column({ space: 4 }) {
              Text(`🎯 目标: ${ticket.goal}`)
                .fontSize(9)
                .fontColor('#cbd5e1')
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })

              if (ticket.stepLogs && ticket.stepLogs.length > 0) {
                Row() {
                  Text(`🛠️ 步骤明细 (${ticket.stepLogs.length})`)
                    .fontSize(8)
                    .fontWeight(FontWeight.Bold)
                    .fontColor('#94a3b8')
                    .layoutWeight(1)
                  Text('最新优先')
                    .fontSize(7)
                    .fontColor('#38bdf8')
                    .backgroundColor('#0369a1')
                    .padding({ left: 3, right: 3, top: 0, bottom: 0 })
                    .borderRadius(2)
                }
                .width('100%')
                .margin({ bottom: 2 })

                Scroll() {
                  Column({ space: 3 }) {
                    ForEach([...ticket.stepLogs].reverse(), (log: TicketStepLog, idx: number) => {
                      Column({ space: 1 }) {
                        Row({ space: 3 }) {
                          Text(`第 ${log.step} 步 [${log.tool}]`)
                            .fontSize(8)
                            .fontWeight(FontWeight.Bold)
                            .fontColor('#38bdf8')
                          if (idx === 0) {
                            Text('最新')
                              .fontSize(7)
                              .fontWeight(FontWeight.Bold)
                              .fontColor('#ffffff')
                              .backgroundColor('#0284c7')
                              .padding({ left: 3, right: 3, top: 0, bottom: 0 })
                              .borderRadius(2)
                          }
                        }
                        .width('100%')

                        if (log.args && log.args.trim().length > 0) {
                          Text(`入参: ${log.args}`)
                            .fontSize(8)
                            .fontColor('#94a3b8')
                            .maxLines(2)
                            .textOverflow({ overflow: TextOverflow.Ellipsis })
                        }
                        if (log.output && log.output.trim().length > 0) {
                          Text(`结果: ${log.output}`)
                            .fontSize(8)
                            .fontColor('#4ade80')
                            .maxLines(2)
                            .textOverflow({ overflow: TextOverflow.Ellipsis })
                        } else if (log.error && log.error.trim().length > 0) {
                          Text(`报错: ${log.error}`)
                            .fontSize(8)
                            .fontColor('#f87171')
                            .maxLines(2)
                            .textOverflow({ overflow: TextOverflow.Ellipsis })
                        }
                      }
                      .width('100%')
                      .padding(3)
                      .backgroundColor(idx === 0 ? '#1e293b' : '#0f172a')
                      .borderRadius(3)
                      .border({ width: idx === 0 ? 0.8 : 0, color: '#38bdf8' })
                      .alignItems(HorizontalAlign.Start)
                    }, (log: TicketStepLog) => `${log.step}_${log.tool}_${log.timestamp}`)
                  }
                  .width('100%')
                }
                .constraintSize({ maxHeight: 100 })
                .scrollBar(BarState.Auto)
              }
            }
            .width('100%')
            .padding(5)
            .backgroundColor('#1e293b')
            .borderRadius(4)
            .alignItems(HorizontalAlign.Start)
          }

          // If WaitingHuman: Question prompt and Quick Response buttons
          if (ticket.status === 'WaitingHuman' && ticket.attention) {
            Column({ space: 4 }) {
              Text(`❓ ${ticket.attention.question}`)
                .fontSize(10)
                .fontColor('#fcd34d')
                .lineHeight(14)

              Row({ space: 6 }) {
                if (ticket.attention.options && ticket.attention.options.length > 0) {
                  ForEach(ticket.attention.options, (opt: string) => {
                    Button(opt)
                      .fontSize(9)
                      .height(20)
                      .backgroundColor('#0284c7')
                      .fontColor('#ffffff')
                      .borderRadius(4)
                      .padding({ left: 6, right: 6 })
                      .onClick(() => {
                        const att = ticket.attention;
                        if (att) {
                          AttentionManager.getInstance().respondAttention(att.id, opt);
                          promptAction.showToast({ message: `已确认: ${opt}`, duration: 1500 });
                        }
                      })
                  }, (opt: string) => opt)
                }

                Blank()

                Button('全屏处理 ↗')
                  .fontSize(9)
                  .height(20)
                  .backgroundColor('#334155')
                  .fontColor('#38bdf8')
                  .borderRadius(4)
                  .padding({ left: 6, right: 6 })
                  .onClick(() => {
                    FloatWindowManager.getInstance().bringAppToForeground();
                  })
              }
              .width('100%')
            }
            .width('100%')
            .padding(6)
            .backgroundColor('#78350f33')
            .border({ width: 1, color: '#f59e0b66' })
            .borderRadius(6)
          }
        }
        .width('100%')
        .padding(8)
        .backgroundColor('#1e293b80')
        .border({ width: 1, color: ticket.status === 'WaitingHuman' ? '#f59e0b55' : '#334155' })
        .borderRadius(8)
      }, (ticket: Ticket) => `${ticket.id}_${ticket.status}_${ticket.progress?.currentStep ?? 0}`)
    }
    .width('100%')
    .padding(8)
    .backgroundColor('#0f172a99')
    .border({ width: 1, color: '#0284c744' })
    .borderRadius(10)
  }

  private hasWaitingHumanTicket(): boolean {
    if (!this.activeTickets || this.activeTickets.length === 0) {
      return false;
    }
    return this.activeTickets.some((t: Ticket) => t.status === 'WaitingHuman');
  }

  private getCompactPulseColor(): string {
    if (this.hasWaitingHumanTicket()) {
      return '#f59e0b';
    }
    if (this.isRunning || this.activeTicketsCount > 0) {
      return '#22c55e';
    }
    return '#38bdf8';
  }

  private getCompactStatusText(): string {
    if (this.hasWaitingHumanTicket()) {
      return '⚠️ 专员等待确认';
    }
    if (this.activeTicketsCount > 0 && this.activeTickets && this.activeTickets.length > 0) {
      const first = this.activeTickets[0];
      const roleName = this.formatRoleName(first.role);
      const action = first.progress?.actionText ? first.progress.actionText : '后台执行中...';
      return `${roleName}: ${action}`;
    }
    if (this.isRunning) {
      return this.currentTool ? `工具: ${this.currentTool}` : '思考中...';
    }
    return '待命';
  }

  private formatRoleName(role: WorkerRole | string): string {
    switch (role) {
      case 'ui_worker':
        return 'UI专员';
      case 'code_worker':
        return '代码专员';
      case 'diag_worker':
        return '诊断专员';
      case 'web_worker':
        return '网络专员';
      case 'general_worker':
      default:
        return '通用专员';
    }
  }

  private getRoleTagColor(role: WorkerRole | string): string {
    switch (role) {
      case 'ui_worker':
        return '#38bdf8';
      case 'code_worker':
        return '#4ade80';
      case 'diag_worker':
        return '#c084fc';
      case 'web_worker':
        return '#22d3ee';
      case 'general_worker':
      default:
        return '#fb923c';
    }
  }

  private getRoleTagBgColor(role: WorkerRole | string): string {
    switch (role) {
      case 'ui_worker':
        return '#0284c726';
      case 'code_worker':
        return '#16a34a26';
      case 'diag_worker':
        return '#9333ea26';
      case 'web_worker':
        return '#0891b226';
      case 'general_worker':
      default:
        return '#ea580c26';
    }
  }

  private handleWindowDrag(event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      if (event.touches.length > 0) {
        this.lastTouchScreenX = event.touches[0].screenX;
        this.lastTouchScreenY = event.touches[0].screenY;
      }
    } else if (event.type === TouchType.Move) {
      if (event.touches.length > 0) {
        const curX = event.touches[0].screenX;
        const curY = event.touches[0].screenY;
        const dx = curX - this.lastTouchScreenX;
        const dy = curY - this.lastTouchScreenY;
        this.lastTouchScreenX = curX;
        this.lastTouchScreenY = curY;
        FloatWindowManager.getInstance().moveWindowBy(dx, dy);
      }
    }
  }

  private stopAgentTask(): void {
    try {
      const session = AppStorage.get<AgentSession>('agentSession');
      if (session) {
        session.abort();
      }
      TicketEngine.getInstance().abortAll();
      promptAction.showToast({ message: '已请求停止 Agent 与后台任务', duration: 1500 });
    } catch (err) {
      hilog.warn(0x3201, 'FloatPanel', 'Failed to stop session: %{public}s', JSON.stringify(err));
    }
  }
}
