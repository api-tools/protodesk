import {describe, expect, it, vi} from 'vitest'
import {flushPromises, mount} from '@vue/test-utils'
import ServersModal from './ServersModal.vue'
import {PickProtoFiles, PickProtoFolder, ValidateProtoSources} from '../../../wailsjs/go/main/App'
import type {ServerProfile} from '../../types/grpc'

vi.mock('../../../wailsjs/go/main/App', () => ({
  PickProtoFiles: vi.fn(),
  PickProtoFolder: vi.fn(),
  ValidateProtoSources: vi.fn(),
}))

const server: ServerProfile = {
  workspaceId: 'local',
  id: 'local',
  name: 'Local',
  address: 'localhost:50051',
  tlsEnabled: false,
  reflectionEnabled: true,
  protoFiles: [],
  protoFolders: [],
  metadataJson: '{}',
}

describe('ServersModal', () => {
  it('adds selected proto files, validates them, and saves the profile', async () => {
    vi.mocked(PickProtoFiles).mockResolvedValue({paths: ['/tmp/protos/service.proto']} as any)
    vi.mocked(ValidateProtoSources).mockResolvedValue({valid: true, fileCount: 1} as any)
    const wrapper = mount(ServersModal, {
      props: {
        open: true,
        servers: [server],
        selectedServerId: server.id,
      },
      global: {
        stubs: {
          Teleport: true,
        },
      },
    })

    await clickButton(wrapper, 'Add files')
    await flushPromises()

    expect(wrapper.text()).toContain('/tmp/protos/service.proto')
    expect(wrapper.text()).toContain('1 proto file validated')

    await wrapper.find('form').trigger('submit')
    await flushPromises()

    expect(ValidateProtoSources).toHaveBeenLastCalledWith({
      protoFiles: ['/tmp/protos/service.proto'],
      protoFolders: [],
    })
    expect(wrapper.emitted('updateServer')?.[0]).toEqual([
      server.id,
      expect.objectContaining({
        protoFiles: ['/tmp/protos/service.proto'],
        protoFolders: [],
      }),
    ])
    expect(wrapper.emitted('close')).toHaveLength(1)
  })

  it('imports proto files from a folder and removes individual entries', async () => {
    vi.mocked(PickProtoFolder).mockResolvedValue({
      folder: '/tmp/protos',
      protoFiles: ['/tmp/protos/a.proto', '/tmp/protos/nested/b.proto'],
    } as any)
    vi.mocked(ValidateProtoSources).mockResolvedValue({valid: true, fileCount: 2} as any)
    const wrapper = mount(ServersModal, {
      props: {
        open: true,
        servers: [server],
        selectedServerId: server.id,
      },
      global: {
        stubs: {
          Teleport: true,
        },
      },
    })

    await clickButton(wrapper, 'Import folder')
    await flushPromises()
    expect(wrapper.text()).toContain('/tmp/protos/a.proto')
    expect(wrapper.text()).toContain('/tmp/protos/nested/b.proto')

    await wrapper.find('[aria-label="Remove proto file"]').trigger('click')

    expect(wrapper.text()).not.toContain('/tmp/protos/a.proto')
    expect(wrapper.text()).toContain('/tmp/protos/nested/b.proto')
  })
})

async function clickButton(wrapper: ReturnType<typeof mount>, label: string) {
  const button = wrapper.findAll('button').find((item) => item.text().includes(label))
  expect(button, `button "${label}"`).toBeTruthy()
  await button!.trigger('click')
}
