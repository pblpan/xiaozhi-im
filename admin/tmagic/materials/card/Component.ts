/*
 * 递归子节点渲染器（容器物料专用）。
 *
 * 来源：Tencent tmagic-editor vue-components/container/src/Component.ts
 * （Apache License 2.0，Copyright (C) 2025 Tencent）——按容器规范拷贝改造：
 * 小智 card 容器需要递归渲染子节点，这是 tmagic 容器的标准实现，
 * 自己重写等于重造轮子且容易漏掉 condResult/visible/data-tmagic-id 这些
 * 编辑器依赖的标记。保留版权头与许可声明。
 */

import { defineComponent, h, inject, type PropType, provide } from 'vue';

import type TMagicApp from '@tmagic/core';
import { Id, IS_DSL_NODE_KEY, MComponent, NODE_CONDS_RESULT_KEY } from '@tmagic/core';
import { useComponent, useComponentStatus, useNode, type UserRenderFunction } from '@tmagic/vue-runtime-help';

export default defineComponent({
  name: 'xz-card-item',

  props: {
    config: {
      type: Object as PropType<Omit<MComponent, 'id'>>,
      required: true,
    },
    index: Number,
    iteratorIndex: {
      type: Array as PropType<number[]>,
      default: () => [],
    },
    iteratorContainerId: {
      type: Array as PropType<Id[]>,
      default: () => [],
    },
    pageFragmentContainerId: {
      type: [String, Number] as PropType<Id>,
      default: '',
    },
  },

  setup(props) {
    const userRender = inject<UserRenderFunction>(
      'userRender',
      ({ h, type, props = {}, attrs = {}, style, className, on }) => {
        const options: Record<string, any> = {
          ...props,
          ...attrs,
          style,
          class: className,
        };
        if (on) {
          for (const [key, handler] of Object.entries(on)) {
            options[`on${key[0].toLocaleUpperCase()}${key.substring(1)}`] = handler;
          }
        }
        return h(type, options);
      },
    );

    const app = inject<TMagicApp>('app');
    const node = useNode(props);

    const componentStatusStore = useComponentStatus(props);

    provide('componentStatusStore', componentStatusStore);

    const { style, className } = componentStatusStore;

    return () => {
      if (
        props.config.visible === false ||
        props.config.condResult === false ||
        (typeof props.config.condResult === 'undefined' && props.config[NODE_CONDS_RESULT_KEY]) ||
        (typeof props.config.display === 'function' && props.config.display({ app, node }) === false)
      ) {
        return null;
      }

      return userRender({
        h,
        config: props.config,
        type: useComponent({ componentType: props.config.type, app }),
        style: style.value,
        className: className.value,
        props: {
          config: { ...props.config, [IS_DSL_NODE_KEY]: true },
          containerIndex: props.index,
          iteratorIndex: props.iteratorIndex,
          iteratorContainerId: props.iteratorContainerId,
          pageFragmentContainerId: props.pageFragmentContainerId,
        },
        attrs: {
          'data-tmagic-id': props.config.id,
          'data-tmagic-iterator-index': props.iteratorIndex.join(',') || undefined,
          'data-tmagic-iterator-container-id': props.iteratorContainerId.join(',') || undefined,
          'data-tmagic-container-index': props.index,
          'data-tmagic-page-fragment-container-id': props.pageFragmentContainerId || undefined,
        },
      });
    };
  },
});
