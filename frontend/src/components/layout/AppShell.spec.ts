import {describe, expect, it, vi} from 'vitest'
import {createPinia} from 'pinia'
import {mount} from '@vue/test-utils'
import AppShell from './AppShell.vue'

vi.mock('../../wailsjs/go/main/App', () => ({
  ClearHistory: vi.fn(),
  Connect: vi.fn(),
  CreateCollection: vi.fn(),
  CreateCollectionRequest: vi.fn(),
  CreateHistoryItem: vi.fn(),
  CreateServerProfile: vi.fn(),
  DeleteCollection: vi.fn(),
  DeleteCollectionRequest: vi.fn(),
  DeleteHistoryItem: vi.fn(),
  DeleteServerProfile: vi.fn(),
  Disconnect: vi.fn(),
  ExportWorkspace: vi.fn(),
  ImportWorkspace: vi.fn(),
  Invoke: vi.fn(),
  ListCollections: vi.fn().mockResolvedValue([]),
  ListHistoryItems: vi.fn().mockResolvedValue([]),
  ListServerProfiles: vi.fn().mockResolvedValue([]),
  PickProtoFiles: vi.fn(),
  PickProtoFolder: vi.fn(),
  UpdateCollection: vi.fn(),
  UpdateCollectionRequest: vi.fn(),
  UpdateServerProfile: vi.fn(),
  ValidateProtoSources: vi.fn(),
}))

describe('AppShell', () => {
  it('renders two accessible column resizers', () => {
    const wrapper = mount(AppShell, {
      global: {
        plugins: [createPinia()],
      },
    })

    const resizers = wrapper.findAll('[role="separator"]')
    expect(resizers).toHaveLength(2)
    expect(resizers[0].attributes('aria-orientation')).toBe('vertical')
    expect(resizers[1].attributes('aria-label')).toContain('request and response')
  })
})
