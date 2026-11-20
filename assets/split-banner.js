import { Component } from '@theme/component';

/**
 * Split banner: plays a column's video while it is hovered or focused.
 * Only active from 1024px on hover-capable screens without reduced motion;
 * elsewhere videos stay paused and the image is shown.
 *
 * @typedef {object} Refs
 * @property {HTMLElement[]} [columns]
 *
 * @extends {Component<Refs>}
 */
class SplitBanner extends Component {
  /** @type {AbortController | undefined} */
  #abortController;

  #query = window.matchMedia('(min-width: 1024px) and (hover: hover) and (prefers-reduced-motion: no-preference)');

  connectedCallback() {
    super.connectedCallback();
    this.#bind();
  }

  updatedCallback() {
    super.updatedCallback();
    this.#bind();
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    this.#abortController?.abort();
  }

  #bind() {
    this.#abortController?.abort();
    this.#abortController = new AbortController();
    const { signal } = this.#abortController;

    for (const column of this.refs.columns ?? []) {
      const video = column.querySelector('video');
      if (!(video instanceof HTMLVideoElement)) continue;

      video.addEventListener('playing', () => column.setAttribute('data-playing', ''), { signal });
      video.addEventListener('pause', () => column.removeAttribute('data-playing'), { signal });

      column.addEventListener('pointerenter', () => this.#play(video), { signal });
      column.addEventListener('pointerleave', () => this.#pause(video, column), { signal });
      column.addEventListener('focusin', () => this.#play(video), { signal });
      column.addEventListener(
        'focusout',
        (event) => {
          // Keep playing while focus moves between elements inside the same column.
          if (event.relatedTarget instanceof Node && column.contains(event.relatedTarget)) return;
          this.#pause(video, column);
        },
        { signal }
      );
    }

    // Stop everything if the layout switches to stacked or motion becomes reduced.
    this.#query.addEventListener(
      'change',
      () => {
        if (this.#query.matches) return;
        for (const video of this.querySelectorAll('video')) video.pause();
      },
      { signal }
    );
  }

  /** @param {HTMLVideoElement} video */
  async #play(video) {
    if (!this.#query.matches) return;
    try {
      await video.play();
    } catch {
      // Playback can be blocked (data saver, autoplay policy); the image stays visible.
    }
  }

  /**
   * @param {HTMLVideoElement} video
   * @param {HTMLElement} column
   */
  #pause(video, column) {
    video.pause();
    column.removeAttribute('data-playing');
  }
}

if (!customElements.get('split-banner-component')) {
  customElements.define('split-banner-component', SplitBanner);
}
