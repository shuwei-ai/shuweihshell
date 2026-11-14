/*
 * Persistent configuration store for the Pi Agent.
 * Stores LLM provider endpoint, API key, model name, and tool execution policy.
 */
import dataPreferences from '@ohos.data.preferences';
import common from '@ohos.app.ability.common';
import { AgentModelConfig, RemoteServerConfig } from './types';

const STORE_NAME = 'swshell_agent_config';
const KEY_BASE_URL = 'agent_base_url';
const KEY_API_KEY = 'agent_api_key';
const KEY_MODEL_NAME = 'agent_model_name';
const KEY_AUTO_RUN_TOOLS = 'agent_auto_run_tools';
const KEY_ENABLE_THINKING = 'agent_enable_thinking';

const KEY_REMOTE_ENABLED = 'remote_ssh_enabled';
const KEY_REMOTE_HOST = 'remote_ssh_host';
const KEY_REMOTE_PORT = 'remote_ssh_port';
const KEY_REMOTE_USER = 'remote_ssh_user';
const KEY_REMOTE_PASSWORD = 'remote_ssh_password';
const KEY_REMOTE_KEY_PEM = 'remote_ssh_key_pem';
const KEY_REMOTE_WORKDIR = 'remote_ssh_workdir';
const KEY_REMOTE_FINGERPRINT = 'remote_ssh_fingerprint';

const DEFAULT_CONFIG: AgentModelConfig = {
  baseUrl: 'https://api.minimax.cn/v1',
  apiKey: '',
  modelName: 'MiniMax-M3.1-Flash',
  autoRunTools: true,
  enableThinking: true
};

const DEFAULT_REMOTE_CONFIG: RemoteServerConfig = {
  enabled: false,
  host: '',
  port: 22,
  username: '',
  password: '',
  privateKeyPem: '',
  defaultWorkDir: '',
  expectedFingerprint: ''
};

export class AgentConfigStore {
  private static instance: AgentConfigStore = new AgentConfigStore();
  private store: dataPreferences.Preferences | undefined = undefined;

  private config: AgentModelConfig = {
    baseUrl: DEFAULT_CONFIG.baseUrl,
    apiKey: DEFAULT_CONFIG.apiKey,
    modelName: DEFAULT_CONFIG.modelName,
    autoRunTools: DEFAULT_CONFIG.autoRunTools,
    enableThinking: DEFAULT_CONFIG.enableThinking
  };

  private remoteConfig: RemoteServerConfig = {
    enabled: DEFAULT_REMOTE_CONFIG.enabled,
    host: DEFAULT_REMOTE_CONFIG.host,
    port: DEFAULT_REMOTE_CONFIG.port,
    username: DEFAULT_REMOTE_CONFIG.username,
    password: DEFAULT_REMOTE_CONFIG.password,
    privateKeyPem: DEFAULT_REMOTE_CONFIG.privateKeyPem,
    defaultWorkDir: DEFAULT_REMOTE_CONFIG.defaultWorkDir,
    expectedFingerprint: DEFAULT_REMOTE_CONFIG.expectedFingerprint
  };

  static getInstance(): AgentConfigStore {
    return AgentConfigStore.instance;
  }

  private async open(context: common.Context): Promise<dataPreferences.Preferences> {
    if (this.store === undefined) {
      this.store = await dataPreferences.getPreferences(context, { name: STORE_NAME });
    }
    return this.store;
  }

  async load(context: common.Context): Promise<AgentModelConfig> {
    try {
      const store = await this.open(context);
      let baseUrl = (await store.get(KEY_BASE_URL, DEFAULT_CONFIG.baseUrl)) as string;
      let apiKey = (await store.get(KEY_API_KEY, DEFAULT_CONFIG.apiKey)) as string;
      let modelName = (await store.get(KEY_MODEL_NAME, DEFAULT_CONFIG.modelName)) as string;
      let autoRun = (await store.get(KEY_AUTO_RUN_TOOLS, DEFAULT_CONFIG.autoRunTools)) as boolean;
      let enableThinking = (await store.get(KEY_ENABLE_THINKING, DEFAULT_CONFIG.enableThinking)) as boolean;

      if (!apiKey || apiKey.trim().length === 0) {
        apiKey = DEFAULT_CONFIG.apiKey;
      }
      if (!baseUrl || baseUrl.trim().length === 0 || baseUrl.includes('deepseek')) {
        baseUrl = DEFAULT_CONFIG.baseUrl;
      }
      if (!modelName || modelName.trim().length === 0 || modelName.includes('deepseek') || modelName.includes('查询')) {
        modelName = DEFAULT_CONFIG.modelName;
      }

      this.config = {
        baseUrl: baseUrl,
        apiKey: apiKey,
        modelName: modelName,
        autoRunTools: autoRun,
        enableThinking: enableThinking
      };

      const rEnabled = (await store.get(KEY_REMOTE_ENABLED, DEFAULT_REMOTE_CONFIG.enabled)) as boolean;
      const rHost = (await store.get(KEY_REMOTE_HOST, DEFAULT_REMOTE_CONFIG.host)) as string;
      const rPort = (await store.get(KEY_REMOTE_PORT, DEFAULT_REMOTE_CONFIG.port)) as number;
      const rUser = (await store.get(KEY_REMOTE_USER, DEFAULT_REMOTE_CONFIG.username)) as string;
      const rPass = (await store.get(KEY_REMOTE_PASSWORD, DEFAULT_REMOTE_CONFIG.password)) as string;
      const rKeyPem = (await store.get(KEY_REMOTE_KEY_PEM, DEFAULT_REMOTE_CONFIG.privateKeyPem)) as string;
      const rWorkDir = (await store.get(KEY_REMOTE_WORKDIR, DEFAULT_REMOTE_CONFIG.defaultWorkDir)) as string;
      const rFingerprint = (await store.get(KEY_REMOTE_FINGERPRINT, DEFAULT_REMOTE_CONFIG.expectedFingerprint)) as string;

      this.remoteConfig = {
        enabled: Boolean(rEnabled),
        host: (rHost ?? '').trim(),
        port: (typeof rPort === 'number' && rPort > 0 && rPort <= 65535) ? rPort : 22,
        username: (rUser ?? '').trim(),
        password: rPass ?? '',
        privateKeyPem: rKeyPem ?? '',
        defaultWorkDir: (rWorkDir ?? '').trim(),
        expectedFingerprint: (rFingerprint ?? '').trim()
      };
    } catch (err) {
      this.config = DEFAULT_CONFIG;
    }
    return this.config;
  }

  getConfig(): AgentModelConfig {
    return this.config;
  }

  getRemoteConfig(): RemoteServerConfig {
    return this.remoteConfig;
  }

  setRemoteConfigMemory(remote: RemoteServerConfig): void {
    this.remoteConfig = remote;
  }

  async saveRemoteConfig(context: common.Context, remote: RemoteServerConfig): Promise<void> {
    this.remoteConfig = remote;
    try {
      const store = await this.open(context);
      await store.put(KEY_REMOTE_ENABLED, remote.enabled);
      await store.put(KEY_REMOTE_HOST, remote.host);
      await store.put(KEY_REMOTE_PORT, remote.port);
      await store.put(KEY_REMOTE_USER, remote.username);
      await store.put(KEY_REMOTE_PASSWORD, remote.password);
      await store.put(KEY_REMOTE_KEY_PEM, remote.privateKeyPem);
      await store.put(KEY_REMOTE_WORKDIR, remote.defaultWorkDir);
      await store.put(KEY_REMOTE_FINGERPRINT, remote.expectedFingerprint);
      await store.flush();
    } catch (err) {
      // Log or swallow
    }
  }

  async save(context: common.Context, newConfig: AgentModelConfig): Promise<void> {
    this.config = newConfig;
    try {
      const store = await this.open(context);
      await store.put(KEY_BASE_URL, newConfig.baseUrl);
      await store.put(KEY_API_KEY, newConfig.apiKey);
      await store.put(KEY_MODEL_NAME, newConfig.modelName);
      await store.put(KEY_AUTO_RUN_TOOLS, newConfig.autoRunTools);
      await store.put(KEY_ENABLE_THINKING, newConfig.enableThinking);
      await store.flush();
    } catch (err) {
      // Log or swallow
    }
  }
}
